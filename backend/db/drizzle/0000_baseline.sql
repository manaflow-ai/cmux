CREATE TABLE "audit_events" (
	"team_id" text NOT NULL,
	"n" bigint NOT NULL,
	"op" text NOT NULL,
	"actor" text NOT NULL,
	"on_behalf_of" text,
	"transaction" text NOT NULL,
	"at" timestamp with time zone NOT NULL,
	"summary" text NOT NULL,
	"detail" jsonb NOT NULL,
	"prev_hash" text NOT NULL,
	"hash" text NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "audit_events_pkey" PRIMARY KEY("team_id","n")
);
--> statement-breakpoint
CREATE TABLE "automation_runs" (
	"id" text PRIMARY KEY NOT NULL,
	"team_id" text NOT NULL,
	"automation_id" text NOT NULL,
	"automation_version" integer NOT NULL,
	"trigger_type" text NOT NULL,
	"trigger" jsonb NOT NULL,
	"state" text NOT NULL,
	"step" integer NOT NULL,
	"error" jsonb,
	"outcome" jsonb,
	"created_at" timestamp with time zone NOT NULL,
	"started_at" timestamp with time zone,
	"finished_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "automations" (
	"id" text PRIMARY KEY NOT NULL,
	"team_id" text NOT NULL,
	"name" text NOT NULL,
	"enabled" boolean NOT NULL,
	"version" integer NOT NULL,
	"definition" jsonb NOT NULL,
	"created_by" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	"next_run_at" timestamp with time zone,
	"deleted_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "connections" (
	"id" text PRIMARY KEY NOT NULL,
	"team_id" text NOT NULL,
	"created_by" text NOT NULL,
	"provider" text NOT NULL,
	"account_key" text,
	"account_name" text,
	"scopes_requested" jsonb NOT NULL,
	"scopes_granted" jsonb NOT NULL,
	"status" text NOT NULL,
	"sharing" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"updated_at" timestamp with time zone NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL
);
--> statement-breakpoint
CREATE TABLE "home_conversations" (
	"id" text PRIMARY KEY NOT NULL,
	"kind" text NOT NULL,
	"team_id" text,
	"title" text,
	"created_by" text,
	"created_at" timestamp with time zone NOT NULL,
	"last_seq" bigint NOT NULL,
	"last_at" timestamp with time zone NOT NULL,
	"participant_count" integer NOT NULL,
	"state" text NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "home_conversations_kind_check" CHECK (kind = ANY (ARRAY['chief'::text, 'dm'::text, 'group'::text])),
	CONSTRAINT "home_conversations_state_check" CHECK (state = ANY (ARRAY['active'::text, 'archived'::text]))
);
--> statement-breakpoint
CREATE TABLE "home_invites" (
	"id" text PRIMARY KEY NOT NULL,
	"conversation_id" text NOT NULL,
	"invited_by" text NOT NULL,
	"address_id" text NOT NULL,
	"channel" text NOT NULL,
	"status" text NOT NULL,
	"delivery_state" text NOT NULL,
	"copy_variant" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"expires_at" timestamp with time zone NOT NULL,
	"accepted_by" text,
	"accepted_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "home_invites_channel_check" CHECK (channel = ANY (ARRAY['email'::text, 'sms'::text])),
	CONSTRAINT "home_invites_status_check" CHECK (status = ANY (ARRAY['pending'::text, 'pending_approval'::text, 'accepted'::text, 'revoked'::text, 'expired'::text]))
);
--> statement-breakpoint
CREATE TABLE "home_participants" (
	"conversation_id" text NOT NULL,
	"participant_id" text NOT NULL,
	"kind" text NOT NULL,
	"visible_from_seq" bigint DEFAULT 0 NOT NULL,
	"joined_at" timestamp with time zone NOT NULL,
	"left_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "home_participants_pkey" PRIMARY KEY("conversation_id","participant_id"),
	CONSTRAINT "home_participants_kind_check" CHECK (kind = ANY (ARRAY['human'::text, 'agent'::text, 'address'::text]))
);
--> statement-breakpoint
CREATE TABLE "hosts" (
	"id" text PRIMARY KEY NOT NULL,
	"team_id" text NOT NULL,
	"owner_user" text NOT NULL,
	"enrolled_by" text NOT NULL,
	"name" text NOT NULL,
	"platform" text NOT NULL,
	"enrolled_at" timestamp with time zone NOT NULL,
	"deleted_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "installs" (
	"id" text PRIMARY KEY NOT NULL,
	"user_id" text NOT NULL,
	"device_id" text NOT NULL,
	"kind" text NOT NULL,
	"name" text NOT NULL,
	"device_name" text NOT NULL,
	"platform" text NOT NULL,
	"thumbprint" text NOT NULL,
	"grant_id" text NOT NULL,
	"created_at" timestamp with time zone NOT NULL,
	"revoked_at" timestamp with time zone,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "memberships" (
	"team_id" text NOT NULL,
	"user_id" text NOT NULL,
	"role" text NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "memberships_pkey" PRIMARY KEY("team_id","user_id"),
	CONSTRAINT "memberships_role_check" CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text, 'member'::text]))
);
--> statement-breakpoint
CREATE TABLE "teams" (
	"id" text PRIMARY KEY NOT NULL,
	"kind" text NOT NULL,
	"stack_team_id" text,
	"display_name" text NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "teams_stack_team_id_key" UNIQUE("stack_team_id"),
	CONSTRAINT "teams_kind_check" CHECK (kind = ANY (ARRAY['personal'::text, 'stack'::text]))
);
--> statement-breakpoint
CREATE TABLE "users" (
	"id" text PRIMARY KEY NOT NULL,
	"stack_user_id" text NOT NULL,
	"email" text,
	"display_name" text NOT NULL,
	"personal_team" text NOT NULL,
	"source_stream" text NOT NULL,
	"source_seq" bigint NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	"updated_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "users_stack_user_id_key" UNIQUE("stack_user_id")
);
--> statement-breakpoint
CREATE UNIQUE INDEX "audit_events_source" ON "audit_events" USING btree ("source_stream" text_ops,"source_seq" int8_ops);--> statement-breakpoint
CREATE INDEX "audit_events_team_at" ON "audit_events" USING btree ("team_id" text_ops,"at" text_ops);--> statement-breakpoint
CREATE INDEX "automation_runs_automation" ON "automation_runs" USING btree ("automation_id" text_ops,"created_at" timestamptz_ops);--> statement-breakpoint
CREATE INDEX "automation_runs_team" ON "automation_runs" USING btree ("team_id" text_ops,"created_at" text_ops);--> statement-breakpoint
CREATE INDEX "automations_team" ON "automations" USING btree ("team_id" text_ops) WHERE (deleted_at IS NULL);--> statement-breakpoint
CREATE INDEX "connections_account" ON "connections" USING btree ("account_key" text_ops) WHERE (account_key IS NOT NULL);--> statement-breakpoint
CREATE INDEX "connections_team" ON "connections" USING btree ("team_id" text_ops);--> statement-breakpoint
CREATE INDEX "home_conversations_team" ON "home_conversations" USING btree ("team_id" text_ops,"last_at" text_ops) WHERE (team_id IS NOT NULL);--> statement-breakpoint
CREATE INDEX "home_invites_address" ON "home_invites" USING btree ("address_id" text_ops,"created_at" timestamptz_ops);--> statement-breakpoint
CREATE INDEX "home_invites_conversation" ON "home_invites" USING btree ("conversation_id" text_ops);--> statement-breakpoint
CREATE INDEX "home_invites_inviter" ON "home_invites" USING btree ("invited_by" timestamptz_ops,"created_at" timestamptz_ops);--> statement-breakpoint
CREATE INDEX "home_participants_member" ON "home_participants" USING btree ("participant_id" text_ops,"conversation_id" text_ops) WHERE (left_at IS NULL);--> statement-breakpoint
CREATE INDEX "hosts_team" ON "hosts" USING btree ("team_id" text_ops) WHERE (deleted_at IS NULL);--> statement-breakpoint
CREATE INDEX "installs_user" ON "installs" USING btree ("user_id" text_ops);--> statement-breakpoint
CREATE INDEX "memberships_user" ON "memberships" USING btree ("user_id" text_ops);