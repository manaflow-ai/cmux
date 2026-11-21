ALTER TABLE "automation_runs" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "automations" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "connections" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "home_conversations" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "home_invites" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "home_participants" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "hosts" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "installs" ADD COLUMN "space" text DEFAULT '' NOT NULL;