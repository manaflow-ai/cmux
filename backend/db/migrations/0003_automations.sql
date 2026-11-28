-- phase: expand
-- Automations (spec cloud-and-automations.md, D13): projections of each team's
-- SchedulerDO, written only by its outbox drain. Definitions and run history for
-- listing, search and admin; the SchedulerDO stays the single writer.

CREATE TABLE automations (
  id             text PRIMARY KEY,
  team_id        text NOT NULL,
  name           text NOT NULL,
  enabled        boolean NOT NULL,
  version        integer NOT NULL,
  definition     jsonb NOT NULL,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  updated_at     timestamptz NOT NULL,
  next_run_at    timestamptz,
  deleted_at     timestamptz,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL
);
CREATE INDEX automations_team ON automations (team_id) WHERE deleted_at IS NULL;

CREATE TABLE automation_runs (
  id                  text PRIMARY KEY,
  team_id             text NOT NULL,
  automation_id       text NOT NULL,
  automation_version  integer NOT NULL,
  trigger_type        text NOT NULL,
  trigger             jsonb NOT NULL,
  state               text NOT NULL,
  step                integer NOT NULL,
  error               jsonb,
  outcome             jsonb,
  created_at          timestamptz NOT NULL,
  started_at          timestamptz,
  finished_at         timestamptz,
  source_stream       text NOT NULL,
  source_seq          bigint NOT NULL,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX automation_runs_automation ON automation_runs (automation_id, created_at DESC);
CREATE INDEX automation_runs_team ON automation_runs (team_id, created_at DESC);
