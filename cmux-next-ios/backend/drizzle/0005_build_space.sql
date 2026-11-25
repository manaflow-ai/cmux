ALTER TABLE "devices" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "push_tokens" ADD COLUMN "space" text DEFAULT '' NOT NULL;--> statement-breakpoint
ALTER TABLE "team_prefs" ADD COLUMN "space" text DEFAULT '' NOT NULL;