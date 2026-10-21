CREATE TABLE "devices" (
	"device_id" uuid PRIMARY KEY NOT NULL,
	"owner_user_id" text NOT NULL,
	"team_id" text NOT NULL,
	"kind" text NOT NULL,
	"name" text NOT NULL,
	"wg_public_key" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	"last_seen_at" timestamp with time zone
);
--> statement-breakpoint
CREATE TABLE "team_prefs" (
	"user_id" text NOT NULL,
	"team_id" text NOT NULL,
	"color" text,
	"emoji" text,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "team_prefs_user_id_team_id_pk" PRIMARY KEY("user_id","team_id")
);
--> statement-breakpoint
CREATE INDEX "devices_team_kind_idx" ON "devices" USING btree ("team_id","kind");--> statement-breakpoint
CREATE INDEX "devices_owner_idx" ON "devices" USING btree ("owner_user_id");