CREATE TABLE `credit_balance` (
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`balance_micros` bigint NOT NULL,
	`held_micros` bigint NOT NULL,
	`last_seq` bigint NOT NULL,
	`changed_at` datetime(3) NOT NULL,
	`version` bigint NOT NULL,
	`updated_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `credit_balance_team_id` PRIMARY KEY(`team_id`)
);
--> statement-breakpoint
CREATE TABLE `credit_ledger` (
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`entry_key` varchar(255) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`kind` varchar(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`micros` bigint NOT NULL,
	`cost_micros` bigint,
	`chief` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`conversation` varchar(64) CHARACTER SET ascii COLLATE ascii_bin,
	`actor` varchar(128),
	`reason` varchar(256),
	`corrects` varchar(255) CHARACTER SET ascii COLLATE ascii_bin,
	`at` datetime(3) NOT NULL,
	`seq` bigint NOT NULL,
	`created_at` datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)),
	CONSTRAINT `credit_ledger_pkey` PRIMARY KEY(`team_id`,`entry_key`),
	CONSTRAINT `credit_ledger_team_seq` UNIQUE(`team_id`,`seq`)
);
--> statement-breakpoint
CREATE TABLE `team_billing_customer` (
	`team_id` varchar(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`mode` varchar(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`customer_id` varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
	`created_at` datetime(3) NOT NULL,
	CONSTRAINT `team_billing_customer_pkey` PRIMARY KEY(`team_id`,`mode`),
	CONSTRAINT `team_billing_customer_customer` UNIQUE(`customer_id`,`mode`)
);
--> statement-breakpoint
CREATE INDEX `credit_ledger_team_at` ON `credit_ledger` (`team_id`,`at`);--> statement-breakpoint
CREATE INDEX `credit_ledger_chief_at` ON `credit_ledger` (`chief`,`at`);