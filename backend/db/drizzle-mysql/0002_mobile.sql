-- phase: expand
-- cmux-mobile-api (cmux-next-ios/backend) device registry, push tokens and team prefs, moved from its own
-- Postgres databases (cmux-mobile-dev, cmux-mobile-prod) into cmux-next-vitess (vitess-migration-DESIGN.md 2.3).
CREATE TABLE `mobile_devices` (
	`device_id` char(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`owner_user_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`name` varchar(1024) NOT NULL,
	`wg_public_key` varchar(255) CHARACTER SET ascii COLLATE ascii_bin,
	`machine_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin,
	`created_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	`last_seen_at` datetime(3),
	CONSTRAINT `mobile_devices_device_id` PRIMARY KEY(`device_id`)
);
--> statement-breakpoint
CREATE INDEX `mobile_devices_team_kind_idx` ON `mobile_devices` (`team_id`,`kind`);
--> statement-breakpoint
CREATE INDEX `mobile_devices_owner_idx` ON `mobile_devices` (`owner_user_id`);
--> statement-breakpoint
CREATE TABLE `mobile_push_tokens` (
	`device_id` char(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`owner_user_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`token` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`environment` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`topic` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kinds` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`muted_macs` text CHARACTER SET ascii COLLATE ascii_bin,
	`previews` boolean,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `mobile_push_tokens_device_id` PRIMARY KEY(`device_id`)
);
--> statement-breakpoint
CREATE INDEX `mobile_push_tokens_owner_idx` ON `mobile_push_tokens` (`owner_user_id`);
--> statement-breakpoint
CREATE INDEX `mobile_push_tokens_token_idx` ON `mobile_push_tokens` (`token`);
--> statement-breakpoint
CREATE TABLE `mobile_team_prefs` (
	`user_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`color` varchar(64),
	`emoji` varchar(64),
	`transparent` boolean NOT NULL DEFAULT false,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `mobile_team_prefs_pkey` PRIMARY KEY(`user_id`,`team_id`)
);
