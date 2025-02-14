# library(rgbif)
library(leaflet)
library(tidyverse)
library(sf)
library(terra)

# get species data --------------------------------------------------------
# my species for modelling
species <- c(
  "Scirpophaga excerptalis",
  "Sesamia grisescens",
  "Chilo auricilia",
  "Chilo infuscatellus",
  "Eumetopina flavipes",
  "Yamatotettix flavovittatus",
  "Perkinsiella saccharicida"
)

# countries for modelling
countries <- list(
  "Scirpophaga excerptalis" = c("India", "Pakistan", "Bangladesh", "Nepal", "Bhutan", "Myanmar", "Thailand", "Laos", "China", "Taiwan", "Japan", "Thailand", "Cambodia", "Vietnam", "Malaysia", "Singapore", "Indonesia", "East Timor", "Papua New Guinea", "Solomon Islands", "Micronesia", "New Caledonia"),
  "Sesamia grisescens" = c("Indonesia", "Papua New Guinea"),
  "Chilio auricilia" = c("Bangladesh", "Bhutan", "Cambodia", "China", "India", "Indonesia", "Laos", "Malaysia", "Myanmar", "Nepal", "Pakistan", "Papua New Guinea", "Philippines", "Sri Lanka", "Taiwan", "Thailand", "Vietnam"),
  "Chilo infuscatellus" = c("India", "Pakistan", "Afghanistan", "Tajikistan", "Uzbekistan", "Bangladesh", "Nepal", "Bhutan", "Myanmar", "Thailand", "Laos", "China", "Taiwan", "South Korea", "North Korea", "Thailand", "Cambodia", "Vietnam", "Malaysia", "Singapore", "Indonesia", "East Timor", "Papua New Guinea", "Philippines", "Brunei"),
  "Eumetopina flavipes" = c("Malaysia", "Brunei", "Indonesia", "Philippines", "Australia", "Papua New Guinea", "Indonesia", "Solomon Islands", "New Caledonia"),
  "Yamatotettix flavovittatus" = c("China", "Indonesia", "Japan", "South Korea", "North Korea", "Laos", "Malaysia", "Myanmar", "Papua New Guinea", "Taiwan", "Thailand", "Brunei"),
  "Perkinsiella saccharicida" = c("Australia", "Malaysia", "Indonesia", "Brunei", "Philippines", "Papua New Guinea", "India", "Sri Lanka", "Taiwan", "China", "United States", "Mexico", "Costa Rica", "Ecaudor", "Réunion")
)

get_species <- function(x, genus = FALSE){
  out <- x %>%
    str_split(" ") %>%
    unlist()
  if(genus){
    return(out[1])
  } else{
    out[2]
  }
}

splist <- list()
genlist <- list()
for(i in seq_along(species)){
  
  gbif_data <- geodata::sp_occurrence(genus = get_species(species[i], TRUE),
                                      species = "*")
  
  if(is.null(gbif_data)) next
  
  sp_coords <- gbif_data %>%
    dplyr::select(lon, lat, status = occurrenceStatus,
                  country, species, genus, family) %>%
    drop_na(lon, lat)
  
  if(nrow(sp_coords) < 2) next
  
  sp_points <- st_as_sf(sp_coords, coords = c("lon", "lat"))
  
  splist[[i]] <- sp_points %>% filter(.data$species == .env$species[i])
  genlist[[i]] <- sp_points
}

# check the number of species
unlist(map(splist, nrow))
unlist(map(genlist, nrow))

# combine all species data
sp_all <- splist %>%
  do.call(bind_rows, .) %>%
  st_set_crs(4326)

tgbs <- genlist %>%
  do.call(bind_rows, .) %>%
  st_set_crs(4326)

write_sf(sp_all, "data/sp_all.gpkg")
write_sf(tgbs, "data/tgbs.gpkg")

head(sp_all)
nrow(sp_all)

species_palette <- colorFactor(palette = viridis::inferno(length(unique(sp_all$species))),
                               domain = unique(sp_all$species))
leaflet() %>%
  addTiles() %>%
  # addMarkers(data = sp_points)
  addCircleMarkers(
    data = sp_all,
    radius = 6,
    stroke = FALSE,
    label = ~species,
    color = ~species_palette(species),
    fillOpacity = 0.4
  )


# raster data -------------------------------------------------------------
# download bioclim layers
bioclim <- geodata::worldclim_global(var = "bio",
                                     res = 0.5,
                                     path = "data/bioclim.tif")

plot(bioclim[[1]])
plot(sp_all$geom, add = TRUE)

# leaflet() %>%
#   addTiles() %>%
#   addRasterImage(raster::raster(bioclim[[1]])) %>%
#   addMarkers(data = sp_all)
# 
# r <- bioclim[[1]] %>%
#   terra::aggregate(fact = 5) %>%
#   raster::raster()
# 
# library(mapview)
# 
# mapview(r)


# Crop raster layers ------------------------------------------------------
fls <- list.files("data/bioclim.tif/wc2.1_30s/",
                  pattern = ".tif$",
                  full.names = TRUE)
bioclim <- terra::rast(fls)
plot(bioclim)

for(i in seq_along(species)){
  sf_use_s2(F)
  
  bg_mask <- geodata::world(path = "data/") %>%
    st_as_sf("MULTIPOLYGON") %>%
    st_transform("WGS84") %>%
    filter(NAME_0 %in% countries[[i]]) %>%
    summarise()
  
  sf_use_s2(T)
  
  # mask raster layers one-by-one
  for(k in 1:nlyr(bioclim)){
    masked <- terra::mask(bioclim[[k]], vect(bg_mask))
    terra::writeRaster(masked, paste0("data/bg_layers/", species[i], "/", names(bioclim)[k], ".tif"), overwrite = T)
    print(k)
  }
  
  print(species[i]) 
}


# KDE for background sampling ---------------------------------------------
# loading required libraries
library(spatialEco)
library(terra)
library(disdat)
library(dismo)
library(sf)

for(i in seq_along(species)){
  
  # read TGB data
  tgbs <- st_read("data/tgbs.gpkg") %>% filter(.data$species == .env$species[i])
  # read a raster mask for the region
  rs <- terra::rast(paste0("data/bg_layers/", species[i], "/wc2.1_30s_bio_1.tif"))
  
  if(!i == 7){
    rs <- rs %>%
      crop(geodata::world(path = "data/") %>%
             st_as_sf("MULTIPOLYGON") %>%
             st_transform("WGS84") %>%
             filter(NAME_0 %in% countries[[i]]) %>%
             summarise() %>%
             vect())
    
    tgbs <- tgbs %>%
      filter(!is.na(extract(rs, st_coordinates(tgbs))))
    
    # remove duplicated points in raster cells
    samplecellID <- terra::cellFromXY(rs, st_coordinates(tgbs)) 
    dup <- duplicated(samplecellID)
    tgbsp <- tgbs[!dup, ]
    
    nrow(tgbs)
    nrow(tgbsp)
    # st_write(tgbsp, "data/tgbs_reduced.gpkg")
    
    tgb_kde <- spatialEco::sp.kde(x = sf::as_Spatial(tgbsp),
                                  bw = 10, # degree
                                  newdata = raster::raster(rs),
                                  standardize = TRUE,
                                  scale.factor = 10000)
    # plot(tgb_kde)
  } else {
    rs1 <- rs %>%
      crop(ext(0, 180, -50, 50))
    
    tgbs1 <- tgbs %>%
      filter(!is.na(extract(rs1, st_coordinates(tgbs))))
    
    # remove duplicated points in raster cells
    samplecellID <- terra::cellFromXY(rs1, st_coordinates(tgbs1)) 
    dup <- duplicated(samplecellID)
    tgbsp <- tgbs1[!dup, ]
    
    nrow(tgbs1)
    nrow(tgbsp)
    # st_write(tgbsp, "data/tgbs_reduced.gpkg")
    
    tgb_kde1 <- spatialEco::sp.kde(x = sf::as_Spatial(tgbsp),
                                  bw = 10, # degree
                                  newdata = raster::raster(rs1),
                                  standardize = TRUE,
                                  scale.factor = 10000)
    
    rs2 <- rs %>%
      crop(ext(-180, 0, -50, 50))
    
    tgbs2 <- tgbs %>%
      filter(!is.na(extract(rs2, st_coordinates(tgbs))))
    
    # remove duplicated points in raster cells
    samplecellID <- terra::cellFromXY(rs2, st_coordinates(tgbs2)) 
    dup <- duplicated(samplecellID)
    tgbsp <- tgbs2[!dup, ]
    
    nrow(tgbs2)
    nrow(tgbsp)
    # st_write(tgbsp, "data/tgbs_reduced.gpkg")
    
    tgb_kde2 <- spatialEco::sp.kde(x = sf::as_Spatial(tgbsp),
                                   bw = 10, # degree
                                   newdata = raster::raster(rs2),
                                   standardize = TRUE,
                                   scale.factor = 10000)
    
    tgb_kde <- terra::merge(rast(tgb_kde1), rast(tgb_kde2))
  }
  
  terra::writeRaster(tgb_kde, paste0("data/bias_layers/", species[i], ".tif"), overwrite = T)
}


# create background data with sampling bias --------------------------

bg_df <- data.frame()
tm <- Sys.time()
for(i in seq_along(species)){
  bmask_i <- rast(paste0("data/bias_layers/", species[i], ".tif"))
  
  samples <- dismo::randomPoints(raster(bmask_i), 
                                 n = 1000, 
                                 prob = TRUE)
  
  bg_df <- samples %>% 
    as.data.frame() %>%
    mutate(species = species[i]) %>% 
    bind_rows(bg_df)
  
  print(species[i])
}
Sys.time() - tm

head(bg_df)
nrow(bg_df)

# read species data
sp_all <- st_read("data/sp_all.gpkg")
# combine background data with species data
sp_all <- sp_all %>% 
  mutate(occ = 1,
         wt = 1) %>% 
  dplyr::select(occ, species, wt)

# function to rename geometry column in sf
rename_geometry <- function(g, name){
  current = attr(g, "sf_column")
  names(g)[names(g)==current] = name
  st_geometry(g)=name
  g
}

species_data <- bg_df %>% 
  mutate(occ = 0, 
         wt = 100000) %>% 
  st_as_sf(coords = c("x", "y")) %>%
  rename_geometry(name = "geom") %>% 
  bind_rows(sp_all)
head(species_data)
nrow(species_data)

st_write(species_data, "data/species_data.gpkg", append = FALSE)


# scale data ------------------------------------------------------------
rst <- rast(lapply(list.files("data/bioclim.tif/wc2.1_30s/",
                              pattern = ".tif$",
                              full.names = TRUE), function(x)
  rast(x) %>% scale())) %>% 
  setNames(c("bio_01", "bio_10", "bio_11",  "bio_12", "bio_13", "bio_14", "bio_15",
             "bio_16", "bio_17", "bio_18", "bio_19", "bio_02", "bio_03", "bio_04", 
             "bio_05", "bio_06", "bio_07", "bio_08", "bio_09"))
plot(rst)

# read EVI layer
evi <- rast("data/evi/evi_virt.vrt") %>% 
  terra::resample(rst[[1]]) %>% 
  terra::scale() %>% 
  setNames("evi")

rst <- c(rst, evi)
plot(rst)

for(i in 1:nlyr(rst)){
  terra::writeRaster(
    rst[[i]], 
    paste0("data/raster_scaled/", names(rst)[i], ".tif"),
    overwrite = T
  )
  print(names(rst)[i])
}

# pca ---------------------------------------------------------------------
files <- list.files("data/raster_scaled/", full.names = TRUE)
files

rst <- rast(files) %>%
  terra::aggregate(fact = 5)

# principal components of a SpatRaster
set.seed(4326)
pca <- values(spatSample(rst, 100000, as.raster=TRUE)) %>% 
  na.omit() %>% 
  as.data.frame() %>%
  prcomp(scale. = T)
plot(pca)

rast_pca <- predict(rst, pca)
plot(rast_pca[[1:4]])

# read species occurrence and background samples
species_data <- st_read("data/species_data.gpkg") %>%
  unique()

# create the training date for modelling
model_data <- terra::extract(rast_pca, vect(species_data), xy = T) %>% 
  mutate(occ = species_data$occ,
         species = as.factor(species_data$species),
         wt = species_data$wt) %>% 
  drop_na()

head(model_data)
nrow(model_data)
table(model_data$occ)
table(model_data$species)

write_csv(model_data, "data/model_data.csv")

# modelling ---------------------------------------------------------------------
## HGAM ##
library(mgcv)
library(caret)
library(biomod2)

model_data <- read_csv("data/model_data.csv") %>%
  mutate(species = as.factor(species))

set.seed(42)
trainIndex <- createFolds(model_data$species, k = 10, returnTrain = TRUE)
# trainIndex <- createDataPartition(model_data$species, p = .8, 
#                                   list = FALSE, 
#                                   times = 1)
# head(trainIndex)

modelPS <- list()
AUC <- numeric()
for(i in 1:length(trainIndex)){
  # calculating the case weights (equal weights)
  # the order of weights should be the same as presences and backgrounds in the training data
  prNum <- as.numeric(table(model_data[trainIndex[[i]],]$occ)["1"]) # number of presences
  bgNum <- as.numeric(table(model_data[trainIndex[[i]],]$occ)["0"]) # number of backgrounds
  iwt <- ifelse(model_data[trainIndex[[i]],]$occ == 1, 1, prNum / bgNum)
  
  modelPS[[i]] <- bam(
    occ ~
      s(PC1, bs = "tp", k = 10, m = 2) +
      s(PC1, species, bs = "fs", m = 1) +
      s(PC2, bs = "tp", k = 10, m = 2) +
      s(PC2, species, bs = "fs", m = 1) +
      s(PC3, bs = "tp", k = 10, m = 2) +
      s(PC3, species, bs = "fs", m = 1) +
      s(PC4, bs = "tp", k = 10, m = 2) +
      s(PC4, species, bs = "fs", m = 1) +
      s(species, bs = "re"),
    data = model_data[trainIndex[[i]],],
    method = "fREML",
    weights = iwt,
    family = binomial(link = "cloglog"),
    discrete = TRUE,
    control = gam.control(trace = FALSE), 
    drop.unused.levels = FALSE
  )
  
  test_df <- model_data[-trainIndex[[i]],] %>%
    mutate(pred = predict(modelPS[[i]],
                          model_data[-trainIndex[[i]],],
                          type = "response"))
  
  AUC[[i]] <- pROC::auc(test_df$occ, test_df$pred)
}

best_model <- modelPS[[which.max(AUC)]]

summary(best_model)

gratia::draw(best_model)
gratia::appraise(best_model)

# spatial prediction ------------------------------------------------------
aus_SA2 <- read_sf("data/2021_Census/SA2_2021_AUST_GDA2020.shp")

sf_use_s2(F)
aus <- st_union(aus_SA2)
sf_use_s2(T)

rst <- rast_pca %>%
  crop(aus_SA2 %>% vect()) %>%
  mask(aus_SA2 %>% vect())

plot(rst[[1:4]])

# make species rasters
facts <- list(species = levels(as.factor(model_data$species)))

for(i in facts$species){
  spname <- i
  r <- rst[[1]]
  r[] <- spname
  spr <- mask(r, rst[[1]])
  names(spr) <- "species"
  
  rast_pred <- c(rst, spr)
  
  prediction <- terra::predict(object = rast_pred, 
                               model = best_model,
                               type = "response"
  )
  
  rast_lab <- str_split(i, " ")[[1]]
  rast_lab[1] <- substr(rast_lab[1], 1, 1)
  rast_lab <- paste(rast_lab, collapse = "_")
  
  newpred <- raster::raster(prediction)
  raster::writeRaster(newpred, paste0("hgam//", rast_lab, ".tif"), overwrite = TRUE)
}

## RANGE BAGGING ##
model_data <- read_csv("data/model_data.csv") %>%
  filter(!species %in% c("Eumetopina flavipes", "Yamatotettix flavovittatus", "Sesamia grisescens")) %>% # sample size too low
  mutate(species = as.factor(species))

facts <- list(species = levels(as.factor(model_data$species)))

for(i in facts$species){
  spname <- i
  
  # Range bagging
  n_models = 100
  n_dim = 3
  sample_prop = 0.5
  
  training <- model_data %>% filter(species == spname, occ == 1)
  training <- training[,2:21]
  
  models <- list()
  
  set.seed(42)
  for(k in 1:n_models){
    # Sample {sample_prop} data rows and {n_dim} variable columns
    # all
    vars <- sample(ncol(training), size = n_dim,
                   replace = FALSE)
    rows <- sample(nrow(training), ceiling(sample_prop*nrow(training)),
                   replace = FALSE)
    sample_data <- training[rows, vars]
    
    models[[k]] <- sample_data[unique(as.vector(
      geometry::convhulln(sample_data, options = 'Pp'))),] 
  }
  
  # Extract data values for object variables
  s_data <- raster::as.data.frame(rst, xy = TRUE, na.rm = TRUE)
  s_coords <- s_data[, c("x", "y")]
  s_data <- as.matrix(s_data[, 3:22])
  
  # Count the number of convex hull model fits for each x data row/cell
  counts <- numeric(nrow(s_data))
  for (k in 1:n_models) {
    vars <- colnames(models[[k]])
    data_in_ch <- geometry::inhulln(
      geometry::convhulln(models[[k]], options = 'Pp'),
      s_data[, vars])
    counts <- counts + data_in_ch
  }
  
  # Return the count fraction as a raster
  prediction <- raster::extend(
    raster::rasterFromXYZ(cbind(s_coords, predicted = counts/n_models),
                          res = raster::res(raster::raster(rst)), crs = raster::crs(raster::raster(rst))),
    raster::extent(raster::raster(rst)))
  
  rast_lab <- str_split(i, " ")[[1]]
  rast_lab[1] <- substr(rast_lab[1], 1, 1)
  rast_lab <- paste(rast_lab, collapse = "_")
  
  raster::writeRaster(prediction, paste0("range bagging//", rast_lab, ".tif"), overwrite = TRUE)
}

## ENSEMBLE ##
library(biomod2)

jar <-
  paste(system.file(package = "dismo"), "/java/maxent.jar", sep = '')

model_data <- read_csv("data/model_data.csv") %>%
  mutate(species = as.factor(species))

facts <- list(species = levels(as.factor(model_data$species)))


for(i in facts$species){
  spname <- i
  
  training <- model_data %>% filter(species == spname)
  
  biomod_data <- BIOMOD_FormatingData(resp.var = training$occ,
                                      expl.var = training[,2:21],
                                      resp.xy = training[,22:23],
                                      resp.name = "occ",
                                      na.rm = TRUE)
  
  # generate SDMs
  biomod_options <- BIOMOD_ModelingOptions(GBM = list(distribution = "bernoulli",
                                                      n.trees = 2500,
                                                      interaction.depth = 3,
                                                      n.minobsinnode = 5,
                                                      learning.rate = 0.01,
                                                      bag.fraction = 0.75,
                                                      train.fraction = 1,
                                                      keep.data = FALSE,
                                                      verbose = FALSE,
                                                      n.cores = 1),
                                           GLM = list(type = 'quadratic',
                                                      interaction.level = 0,
                                                      myFormula = NULL,
                                                      test = 'AIC',
                                                      family = binomial(link = 'logit'),
                                                      mustart = 0.5,
                                                      control = glm.control(epsilon = 1e-08, maxit = 50, trace = FALSE)),
                                           MAXENT = list(path_to_maxent.jar = jar, 
                                                         memory_allocated = 512,
                                                         initial_heap_size = NULL,
                                                         maximum_heap_size = NULL,
                                                         background_data_dir = 'default',
                                                         maximumbackground = 'default',
                                                         maximumiterations = 200,
                                                         visible = FALSE,
                                                         linear = TRUE,
                                                         quadratic = TRUE,
                                                         product = TRUE,
                                                         threshold = TRUE,
                                                         hinge = TRUE,
                                                         lq2lqptthreshold = 80,
                                                         l2lqthreshold = 10,
                                                         hingethreshold = 15,
                                                         beta_threshold = -1,
                                                         beta_categorical = -1,
                                                         beta_lqp = -1,
                                                         beta_hinge = -1,
                                                         betamultiplier = 1,
                                                         defaultprevalence = 0.5))
  
  biomod_model_out <- BIOMOD_Modeling(biomod_data,
                                      models = c('GBM','GLM','GAM','MAXENT','RF'),
                                      bm.options = biomod_options,
                                      CV.strategy = 'block',
                                      metric.eval = c('ROC', 'TSS'),
                                      weights = training$wt,
                                      seed.val = 42)
  
  # generate ensemble model
  ens_model <- BIOMOD_EnsembleModeling(biomod_model_out,
                                       em.by = "all",
                                       em.algo = 'EMwmean',
                                       metric.eval = c('ROC', 'TSS'))
  
  ens_pred <- BIOMOD_EnsembleForecasting(bm.em = ens_model,
                                         models.chosen = get_built_models(ens_model)[[2]],
                                         proj.name = "ens",
                                         new.env = rst,
                                         build.clamping.mask = FALSE,
                                         output.format = ".tif")
  
  pr <- raster::raster(get_predictions(ens_pred)/1000)
  
  rast_lab <- str_split(i, " ")[[1]]
  rast_lab[1] <- substr(rast_lab[1], 1, 1)
  rast_lab <- paste(rast_lab, collapse = "_")
  
  raster::writeRaster(pr, paste0("ensemble//", rast_lab, ".tif"), overwrite = TRUE)
}

# mask by host plants ------------------------------------------------------
commodities <- read_sf("data/CLUM_Commodities_2020.shp")

all_comms <- c("barley", "maize", "oats", "rice", "sorghum", "sugar cane", "wheat")

sf_use_s2(FALSE)

for(i in seq_along(all_comms)){
  write_sf(commodities %>%
             filter(Commod_dsc %in% all_comms[i]) %>%
             summarise,
           paste0("host_shp/", all_comms[i], ".gpkg"),
           overwrite = T)
}

sf_use_s2(TRUE)
# 
# ### Chilo infuscatellus ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("barley", "maize", "oats", "rice", "sorghum", "sugar cane")),
#          "host_shp/C_infuscatellus.gpkg", overwrite = T)
# 
# ### Eumetopina flavipes ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("sugar cane")),
#          "host_shp/E_flavipes.gpkg", overwrite = T)
# 
# ### Perkinsiella saccharicida ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("rice", "sorghum", "maize", "sugar cane")),
#          "host_shp/P_saccharicida.gpkg", overwrite = T)
# 
# ### Scirpophaga excerptalis ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("wheat", "sugar cane")),
#          "host_shp/S_excerptalis.gpkg", overwrite = T)
# 
# ### Sesamia grisescens ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("rice", "sugar cane")),
#          "host_shp/S_grisescens.gpkg", overwrite = T)
# 
# ### Yamatotettix flavovittatus ###
# write_sf(commodities %>%
#            filter(Commod_dsc %in% c("sugar cane")),
#          "host_shp/Y_flavovittatus.gpkg", overwrite = T)
# 
