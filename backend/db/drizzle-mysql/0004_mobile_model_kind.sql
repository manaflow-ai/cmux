-- phase: expand
-- Keep the mobile platform kind (mac/phone) separate from the model used to draw its glyph.
ALTER TABLE `mobile_devices` ADD COLUMN `model_kind` varchar(32) CHARACTER SET ascii COLLATE ascii_bin;
