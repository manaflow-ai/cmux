CREATE TABLE `audit_events` (
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`n` bigint NOT NULL,
	`op` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`actor` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`on_behalf_of` varchar(128) CHARACTER SET ascii COLLATE ascii_bin,
	`transaction` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`at` datetime(3) NOT NULL,
	`summary` text NOT NULL,
	`detail` json NOT NULL,
	`prev_hash` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`hash` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`created_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `audit_events_pkey` PRIMARY KEY(`team_id`,`n`),
	CONSTRAINT `audit_events_source` UNIQUE(`source_stream`,`source_seq`)
);
--> statement-breakpoint
CREATE TABLE `automation_runs` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`automation_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`automation_version` int NOT NULL,
	`trigger_type` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`trigger` json NOT NULL,
	`state` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`step` int NOT NULL,
	`error` json,
	`outcome` json,
	`created_at` datetime(3) NOT NULL,
	`started_at` datetime(3),
	`finished_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `automation_runs_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `automations` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`name` varchar(512) NOT NULL,
	`enabled` boolean NOT NULL,
	`version` int NOT NULL,
	`definition` json NOT NULL,
	`created_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`updated_at` datetime(3) NOT NULL,
	`next_run_at` datetime(3),
	`deleted_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	CONSTRAINT `automations_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `connections` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`provider` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`account_key` varchar(255) CHARACTER SET ascii COLLATE ascii_bin,
	`account_name` varchar(512),
	`scopes_requested` json NOT NULL,
	`scopes_granted` json NOT NULL,
	`status` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`sharing` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`updated_at` datetime(3) NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	CONSTRAINT `connections_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `home_conversations` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`title` varchar(512),
	`created_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`created_at` datetime(3) NOT NULL,
	`last_seq` bigint NOT NULL,
	`last_at` datetime(3) NOT NULL,
	`participant_count` int NOT NULL,
	`state` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `home_conversations_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `home_invites` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`conversation_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`invited_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`address_id` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`channel` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`status` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`delivery_state` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`copy_variant` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`expires_at` datetime(3) NOT NULL,
	`accepted_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`accepted_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `home_invites_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `home_message_search` (
	`conversation_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`seq` bigint NOT NULL,
	`message_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`author_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`author_kind` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`edited_at` datetime(3),
	`body` text NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	CONSTRAINT `home_message_search_pkey` PRIMARY KEY(`conversation_id`,`seq`)
);
--> statement-breakpoint
CREATE TABLE `home_participants` (
	`conversation_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`participant_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`visible_from_seq` bigint NOT NULL DEFAULT 0,
	`joined_at` datetime(3) NOT NULL,
	`left_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `home_participants_pkey` PRIMARY KEY(`conversation_id`,`participant_id`)
);
--> statement-breakpoint
CREATE TABLE `hosts` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`owner_user` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`enrolled_by` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`name` varchar(512) NOT NULL,
	`platform` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`enrolled_at` datetime(3) NOT NULL,
	`deleted_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `hosts_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `installs` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`user_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`device_id` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`name` varchar(512) NOT NULL,
	`device_name` varchar(512) NOT NULL,
	`platform` varchar(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`thumbprint` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`grant_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	`revoked_at` datetime(3),
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `installs_id` PRIMARY KEY(`id`)
);
--> statement-breakpoint
CREATE TABLE `memberships` (
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`user_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`role` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `memberships_pkey` PRIMARY KEY(`team_id`,`user_id`)
);
--> statement-breakpoint
CREATE TABLE `teams` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`stack_team_id` varchar(128) CHARACTER SET ascii COLLATE ascii_bin,
	`display_name` varchar(512) NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`created_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `teams_id` PRIMARY KEY(`id`),
	CONSTRAINT `teams_stack_team_id_key` UNIQUE(`stack_team_id`)
);
--> statement-breakpoint
CREATE TABLE `users` (
	`id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`stack_user_id` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`email` varchar(320),
	`display_name` varchar(512) NOT NULL,
	`personal_team` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_stream` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`source_seq` bigint NOT NULL,
	`created_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `users_id` PRIMARY KEY(`id`),
	CONSTRAINT `users_stack_user_id_key` UNIQUE(`stack_user_id`)
);
--> statement-breakpoint
CREATE INDEX `audit_events_team_at` ON `audit_events` (`team_id`,`at`);--> statement-breakpoint
CREATE INDEX `automation_runs_automation` ON `automation_runs` (`automation_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `automation_runs_team` ON `automation_runs` (`team_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `automations_team` ON `automations` (`team_id`,`deleted_at`);--> statement-breakpoint
CREATE INDEX `connections_account` ON `connections` (`account_key`);--> statement-breakpoint
CREATE INDEX `connections_team` ON `connections` (`team_id`);--> statement-breakpoint
CREATE INDEX `home_conversations_team` ON `home_conversations` (`team_id`,`last_at`);--> statement-breakpoint
CREATE INDEX `home_invites_address` ON `home_invites` (`address_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `home_invites_conversation` ON `home_invites` (`conversation_id`);--> statement-breakpoint
CREATE INDEX `home_invites_inviter` ON `home_invites` (`invited_by`,`created_at`);--> statement-breakpoint
CREATE INDEX `home_message_search_recent` ON `home_message_search` (`conversation_id`,`created_at`);--> statement-breakpoint
CREATE INDEX `home_participants_member` ON `home_participants` (`participant_id`,`left_at`,`conversation_id`);--> statement-breakpoint
CREATE INDEX `hosts_team` ON `hosts` (`team_id`,`deleted_at`);--> statement-breakpoint
CREATE INDEX `installs_user` ON `installs` (`user_id`);--> statement-breakpoint
CREATE INDEX `memberships_user` ON `memberships` (`user_id`);