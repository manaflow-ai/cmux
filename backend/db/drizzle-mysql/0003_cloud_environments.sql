-- phase: expand
-- cloud_environments: CloudDO projects one summary row per Cloud environment (plans/cmux-next/cloud-environments-DESIGN.md §7). No foreign keys, no triggers.
CREATE TABLE `cloud_environments` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`name` varchar(80) NOT NULL,
	`repo` varchar(300),
	`status` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`snapshot_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`created_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`updated_at` datetime(3) NOT NULL,
	`deleted_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	CONSTRAINT `cloud_environments_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE INDEX `cloud_environments_team` ON `cloud_environments` (`team_id`,`deleted_at`);