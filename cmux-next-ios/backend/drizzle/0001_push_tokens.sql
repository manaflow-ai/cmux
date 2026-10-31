CREATE TABLE "push_tokens" (
	"device_id" uuid PRIMARY KEY NOT NULL,
	"owner_user_id" text NOT NULL,
	"token" text NOT NULL,
	"environment" text NOT NULL,
	"topic" text NOT NULL,
	"kinds" text NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE INDEX "push_tokens_owner_idx" ON "push_tokens" USING btree ("owner_user_id");