-- phase: expand
-- cmux-mobile-api build spaces (cmux-next-ios/PROTOCOL.md "Build spaces"): every row records the build that wrote
-- it, "" for stable and nightly, `dev:<slug>` for a dev build, and the Worker filters every read on it. Existing rows
-- read as stable. Apply before deploying the Worker that writes the column (it names `space` in every statement).
-- Primary keys stay as they are: device ids are per build (a tagged build has its own id), so a device id held by
-- another space is refused rather than keyed twice, and team prefs keep (user_id, team_id) with a dev space's
-- user_id prefixed `dev:<slug>|`. Moving `space` into a primary key would be a DROP/ADD PRIMARY KEY, which the
-- migration guard refuses (it needs a PlanetScale deploy request and a written plan), and nothing needs it now.
ALTER TABLE `mobile_devices` ADD COLUMN `space` varchar(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '';
--> statement-breakpoint
ALTER TABLE `mobile_push_tokens` ADD COLUMN `space` varchar(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '';
--> statement-breakpoint
ALTER TABLE `mobile_team_prefs` ADD COLUMN `space` varchar(80) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT '';
