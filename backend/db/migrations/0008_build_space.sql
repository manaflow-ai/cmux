-- phase: expand
-- Build spaces (apps/api/src/build-space.ts): a tagged dev build's per-build rows carry its space
-- (`dev:<slug>`); nightly and stable rows keep the default ''. Every key of a dev build's row is written
-- as `dev:<slug>|<id>` (the name scheme of its Durable Objects), so a dev build's deterministic ids
-- (DM conversations) never meet nightly's rows and no primary key changes. Reads filter on `space`.
-- Adding a column with a constant default is metadata only in Postgres 11+: no table rewrite, no long lock.
ALTER TABLE installs ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE hosts ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE automations ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE automation_runs ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE connections ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE home_conversations ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE home_invites ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE home_participants ADD COLUMN space text DEFAULT '' NOT NULL;
ALTER TABLE home_message_search ADD COLUMN space text DEFAULT '' NOT NULL;
