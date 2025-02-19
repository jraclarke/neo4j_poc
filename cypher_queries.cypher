############################################################################################################################################################################

------------------------
BNG DB Setup
------------------------

//864kb on creation

// Original file with the BNG points:
:auto LOAD CSV WITH HEADERS FROM "file:///Romsey_SU3520_03082021_nadir_classified.txt" AS csvLine
CALL {
  WITH csvLine
CREATE (:PointCloudPoint {longitude: toFloat(csvLine.X), latitude: toFloat(csvLine.Y), z: toFloat(csvLine.Z), classification: toFloat(csvLine.Classification)})
} IN TRANSACTIONS OF 10000 ROWS
//4.5GB after


//Load the classifications
:auto LOAD CSV WITH HEADERS FROM "file:///ASPRS_LAS_classifications.txt" AS csvLine
CALL {
  WITH csvLine
CREATE (:ASPRSClassifications {ID: toString(csvLine.ID), Description: toString(csvLine.Description)})
} ;
CREATE CONSTRAINT uniqueASPRSClassification IF NOT EXISTS FOR (c:ASPRSClassifications) REQUIRE c.Description IS UNIQUE;

// Obtain (https://github.com/neo4j-contrib/spatial/releases) and load the neo4j-spatial*.jar files into the plugin directory for the DB (.config/Neo4j Desktop/ etc.).

// Add comma separated "spatial.*" to dbms.security.procedures.unrestricted
// Change the max heap size to 4G 

// Restart DBMS

// Create a spatial layer for BNG
CALL spatial.addLayer('romsey_bng_layer', 'SimplePoint', '');

// Create spatial index (batched) by adding nodes to spatial layer.
// This works. Takes 560s for 129 batches (ran a few testers before). Could be quicker with higher batchsize, 
// though need to test memory constraints. The :RTREE... means that it has that reference associated with it
// i.e. it is part of the spatial index.
:auto
CALL apoc.periodic.iterate( 
	"MATCH (n:PointCloudPoint) 
	WHERE NOT (n)<-[:RTREE_REFERENCE]-() RETURN n", 
	"WITH collect(n) AS nodes CALL spatial.addNodes('romsey_bng_layer', nodes) YIELD count RETURN count", 
	{ batchSize: 400000, parallel: true } ) ;
// 6.8GB afterwards (index is 2.4 GB)


MATCH (n:PointCloudPoint), (c:ASPRSClassifications) 
   WHERE n.classification = c.ID
   LIMIT 10
CREATE (n)-[:HAS_CLASSIFICATION]->(c) 
RETURN n,c


------------------------
Spatial queries
------------------------

//Return the first 10 nodes from the PCP layer (gives a general idea of coords etc)
match (n:PointCloudPoint)
With n limit 10
return n

// Test the spatial index. for bng lat=northing, lon=easting. Return everything within BB.
CALL spatial.bbox('romsey_bng_layer',{lon:435000,lat:120830}, {lon:435010, lat:120840})

// Same but for the count
CALL spatial.bbox('romsey_bng_layer',{lon:435000,lat:120830}, {lon:435010, lat:120840})
YIELD node RETURN count(node) AS nodeCount;

//Return every point with a classification of 6.
match (n:PointCloudPoint)
where n.classification = 6
return n.longitude, n.latitude;

############################################################################################################################################################################

--------------------------
Create WGS84 DB

// 317 seconds
:auto LOAD CSV WITH HEADERS FROM "file:///Romsey_SU3520_03082021_nadir_classified_wgs84.txt" AS csvLine
CALL {
  WITH csvLine
CREATE (:PointCloudPoint {geometry: point({latitude: toFloat(csvLine.Y), longitude: toFloat(csvLine.X), height: toFloat(csvLine.Z)}), classification: toFloat(csvLine.Classification), crs: "WGS-84-3D"})
} IN TRANSACTIONS OF 100000 ROWS
// 4.5GB after

// Create the native point index on the above.
CREATE POINT INDEX node_point_index_name FOR (n:Person) ON (n.sublocation)

############################################################################################################################################################################

----------------------------------------------------------------------------------------
--Teardown
----------------------------------------------------------------------------------------

// Delete points
//
:auto
MATCH (n:PointCloudPoint)
CALL {
WITH n
DETACH DELETE n
} IN TRANSACTIONS OF 10000 ROWS

//Delete classifications layer
:auto
MATCH (n:ASPRSClassifications)
DETACH DELETE n


//Delete relationships on layer:
:auto
MATCH (a:ASPRSClassifications)-[r:HAS_CLASSIFICATION]->(n:PointCloudPoint)
CALL {
with r
DELETE r
} IN TRANSACTIONS OF 100000 ROWS


// Remove spatial layer
CALL spatial.removeLayer('romsey_bng_layer');

DROP CONSTRAINT uniqueASPRSClassification;

//Notes

return will only work in a call // (as its a procedure)


------------------------------------------------------------------------
--For reference
------------------------------------------------------------------------
//And with a different method (keeping for syntax of periodic.commit). 
:auto
call apoc.periodic.commit(
	"match (n:PointCloudPoint) 
	where not (n)-[:RTREE_REFERENCE]-() with n limit $limit
	WITH collect(n) AS pnodes 
	CALL spatial.addNodes('romsey_bng_layer', pnodes) YIELD count return count",
	{limit:10000}
)


// Create a spatial index for BNG (fails due to memory, kept for reference.)
MATCH (n:Point)
WITH collect(n) AS nodes
CALL spatial.addNodes('romsey_bng_layer', nodes) YIELD count
RETURN count;




// Create spatial index (10000 rows)
// This works but just for 10000 (this needs to be put into loop etc.). Takes 16 seconds.
match (n:PointCloudPoint)
WHERE NOT (n)<-[:RTREE_REFERENCE]-()
With n limit 100000
with collect(n) as nodes CALL spatial.addNodes("romsey_bng_layer",nodes) yield count return count


// Redundant as lookup tables not really required in graph DBs.
// Create classification relationship.
// Parallelisation causes lock failures.
// Run before spatial index creation
//405s
:auto
CALL apoc.periodic.iterate(
  "MATCH (n:PointCloudPoint) RETURN n",
  "MATCH (c:ASPRSClassifications {Description: n.classification})
   CREATE (n)-[:HAS_CLASSIFICATION]->(c)",
  {batchSize: 100000, parallel: false}
);



-------------------
Notes
-------------------

Removing spatial layer removes nodes.
If you want to remove spatial layer you need to remove nodes first then re-add.

