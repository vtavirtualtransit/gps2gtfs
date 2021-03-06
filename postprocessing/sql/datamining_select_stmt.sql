-- some aggregate functions need to be created first, see
-- aggregate_functions.sql
insert into datamining_table (

select gst.gps_segment_id, 
       gsegs.trip_id as gtfs_trip_id, 
       gsegs.schedule_error as rms_schedule_error,
       gsegs.vehicle_id as vehicle_id,
       routes.route_short_name as route_name, 
       rtypes.description as vehicle_type,
       trips.service_id, 
       trips.direction_id, 
       stops.stop_lat as stop_lat,
       stops.stop_lon as stop_lon, 
       stops.stop_id as stop_id, 
       gst.stop_sequence, 
       gst.arrival_time_seconds as scheduled_arrival_time, 
       gst.departure_time_seconds as scheduled_departure_time, 
       gst.actual_arrival_time_seconds as actual_arrival_time,
       gst.actual_departure_time_seconds as actual_departure_time,

       CASE
         WHEN sinfo.trip_stop_number = 0
           THEN null
         ELSE gst.actual_arrival_time_seconds-arrival_time_seconds 
       END as lateness_arrive,

       CASE
         WHEN sinfo.trip_stop_number = tinfo.total_num_stops-1
           THEN null
         ELSE gst.actual_departure_time_seconds-departure_time_seconds
       END as lateness_depart,

       gst.seconds_since_last_stop as seconds_since_last_stop,
       gst.prev_stop_id as prev_stop_id,
       CASE 
         WHEN gst.arrival_time_seconds < 0 
	  THEN (gst.arrival_time_seconds+86400)/3600
         WHEN gst.arrival_time_seconds >= 86400 
	  THEN (gst.arrival_time_seconds-86400)/3600
         ELSE gst.arrival_time_seconds/3600
       END as scheduled_hour_of_arrival,

       tinfo.first_arrival-gsegs.schedule_offset_seconds
         as sched_trip_start_time,
       tinfo.trip_length_meters as trip_length_meters,
       tinfo.trip_duration_seconds as trip_duration_seconds,

       sinfo.trip_stop_number as stop_number,
       sinfo.prev_stop_distance_meters as prev_stop_distance,
       sinfo.cumulative_distance_meters as stop_distance



from gps_stop_times gst 
     --inner join random_gps_segments rgs on rgs.gps_segment_id=gst.gps_segment_id
     inner join gps_segments gsegs on gst.gps_segment_id=gsegs.gps_segment_id
     inner join gtf_stops stops on gst.stop_id=stops.stop_id 
     inner join gtf_trips trips on trips.trip_id = gsegs.trip_id 
     inner join gtf_routes routes on routes.route_id = trips.route_id
     inner join gtfs_route_types rtypes on rtypes.route_type=routes.route_type
     inner join gtf_trip_information tinfo on tinfo.trip_id = gsegs.trip_id
     inner join gtf_stoptimes_information sinfo on sinfo.trip_id = gsegs.trip_id
                and sinfo.stop_sequence = gst.stop_sequence

order by gst.gps_segment_id, gst.stop_sequence

);


create index dmix_rss on datamining_table(route_name,prev_stop_id,stop_id);
create index dm_selfjoin_idx on datamining_table(gps_segment_id,stop_number);

alter table datamining_table add column lateness_gained int;

update only datamining_table d2 
set lateness_gained = d2.lateness-d1.lateness
from datamining_table d1 
where d1.lateness is not null and d2.lateness is not null
      and d1.gps_segment_id=d2.gps_segment_id 
      and d1.stop_number+1=d2.stop_number;



select avg(seconds_since_last_stop) as mean, 
       stddev(seconds_since_last_stop) as std,
       median(seconds_since_last_stop) as med,
       MAD(seconds_since_last_stop) as mad,
       count(*) as num,
       route_name,prev_stop_id,stop_id
into routehop_means 
from datamining_table 
where seconds_since_last_stop is not null
group by route_name,prev_stop_id,stop_id;

alter table routehop_means add column left_std double precision;
alter table routehop_means add column right_std double precision;
alter table routehop_means add column left_mad double precision;
alter table routehop_means add column right_mad double precision;

update routehop_means orm set left_std = t.ls
from
(select avg( (dm.seconds_since_last_stop-irm.mean)^2 ) as ls,
	route_name,prev_stop_id,stop_id
 from datamining_table dm natural join routehop_means irm
 where dm.seconds_since_last_stop < irm.mean
 group by route_name,prev_stop_id,stop_id) t
where t.route_name=orm.route_name
      and t.prev_stop_id=orm.prev_stop_id
      and t.stop_id=orm.stop_id;

update routehop_means orm set right_std = t.rs
from
(select avg( (dm.seconds_since_last_stop-irm.mean)^2 ) as rs,
	route_name,prev_stop_id,stop_id
 from datamining_table dm natural join routehop_means irm
 where dm.seconds_since_last_stop > irm.mean
 group by route_name,prev_stop_id,stop_id) t
where t.route_name=orm.route_name
      and t.prev_stop_id=orm.prev_stop_id
      and t.stop_id=orm.stop_id;

update routehop_means orm set left_mad = t.lm
from
(select median( abs(dm.seconds_since_last_stop-irm.med) ) as lm,
	route_name,prev_stop_id,stop_id
 from datamining_table dm natural join routehop_means irm
 where dm.seconds_since_last_stop < irm.med
 group by route_name,prev_stop_id,stop_id) t
where t.route_name=orm.route_name
      and t.prev_stop_id=orm.prev_stop_id
      and t.stop_id=orm.stop_id;

update routehop_means orm set right_mad = t.rm
from
(select median( abs(dm.seconds_since_last_stop-irm.med) ) as rm,
	route_name,prev_stop_id,stop_id
 from datamining_table dm natural join routehop_means irm
 where dm.seconds_since_last_stop > irm.med
 group by route_name,prev_stop_id,stop_id) t
where t.route_name=orm.route_name
      and t.prev_stop_id=orm.prev_stop_id
      and t.stop_id=orm.stop_id;


-- normalized seconds_since_last_stop
alter table datamining_table add column meannorm_ssls numeric;
alter table datamining_table add column  madnorm_ssls numeric;

update only datamining_table d1 
set meannorm_ssls = (d1.seconds_since_last_stop-rm.mean)/rm.std
from routehop_means rm
where rm.route_name=d1.route_name
      and rm.prev_stop_id=d1.prev_stop_id
      and rm.stop_id=d1.stop_id
      and rm.std != 0;

update only datamining_table d1 
set madnorm_ssls = (d1.seconds_since_last_stop-rm.med)/rm.mad
from routehop_means rm
where rm.route_name=d1.route_name
      and rm.prev_stop_id=d1.prev_stop_id
      and rm.stop_id=d1.stop_id
      and rm.mad != 0;




-- Statistical Weighting Calculations --

select count(*) from datamining_table where lateness_arrive is not null;
-- Result = Total rows with non-null lateness_arrive = 1825415

select count(*) from datamining_table where lateness_depart is not null;
-- Result = Total rows with non-null lateness_depart = 1855810

select service_id,count(*) 
  from gtf_stoptimes_information gsi
    natural join gtf_trips gt
    natural join gtf_trip_information gti
  where gti.total_num_stops-1 != gsi.trip_stop_number
group by service_id
order by service_id;
-- Result = Total number (trip,stop)s departures on any given:
--    weekday (sid=1) = 462872
--   saturday (sid=2) = 372007
--     sunday (sid=3) = 350173

select service_id,count(*) 
  from gtf_stoptimes_information gsi
    natural join gtf_trips gt
    natural join gtf_trip_information gti
  where gsi.trip_stop_number != 0
group by service_id
order by service_id;
-- Result = Total number (trip,stop)s departures on any given:
--    weekday (sid=1) = 462872
--   saturday (sid=2) = 372007
--     sunday (sid=3) = 350173

-- (They are identical, as they should be.)

select 5*462872 + 372007 + 350173;
-- Result: there are 3036540 total (trip,stop) arrivals/departures every week
-- Therefore a weekday (trip,stop) should have 5/3036540 of the total
-- count, and a weekend (trip,stop) should have 1/3036540 of the total.


select gtfs_trip_id,stop_id,
count(lateness_arrive) as inclusion_count_arrive,
count(lateness_arrive) / 1825415::double precision as inclusion_frequency_arrive,
count(lateness_depart) as inclusion_count_depart,
count(lateness_depart) / 1855810::double precision as inclusion_frequency_depart,

case when service_id='1' then 5/3036540::double precision
     else                     1/3036540::double precision
end as scheduled_frequency,

case 
  when service_id='1' and count(lateness_arrive) > 0
    then (5*1825415)/(count(lateness_arrive)*3036540::double precision)
  when service_id != '1' and count(lateness_arrive) > 0
    then (1*1825415)/(count(lateness_arrive)*3036540::double precision)
  else null
end as trip_stop_weight_arrive,

case 
  when service_id='1' and count(lateness_depart) > 0
    then (5*1855810)/(count(lateness_depart)*3036540::double precision)
  when service_id != '1' and count(lateness_depart) > 0
    then (1*1855810)/(count(lateness_depart)*3036540::double precision)
  else null
end as trip_stop_weight_depart

into trip_stop_weights
from datamining_table dm
where lateness_arrive is not null or lateness_depart is not null
group by gtfs_trip_id, stop_id, service_id;

create index tsweight_ix on trip_stop_weights (gtfs_trip_id,stop_id);

