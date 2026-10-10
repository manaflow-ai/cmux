-- phase: expand
-- Team audit log (spec/enterprise.md section 6): one row per admin action
-- (policy, enrollment, device management), written only by the outbox drain
-- of the owner that committed it. Each row hashes the previous row of the
-- same team (prev_hash, hash), so a removed or edited row breaks the chain.
-- Rows are never updated: a replayed drain inserts nothing.

CREATE TABLE audit_events (
  team_id        text NOT NULL,
  n              bigint NOT NULL,
  op             text NOT NULL,
  actor          text NOT NULL,
  on_behalf_of   text,
  transaction    text NOT NULL,
  at             timestamptz NOT NULL,
  summary        text NOT NULL,
  detail         jsonb NOT NULL,
  prev_hash      text NOT NULL,
  hash           text NOT NULL,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, n)
);
CREATE UNIQUE INDEX audit_events_source ON audit_events (source_stream, source_seq);
CREATE INDEX audit_events_team_at ON audit_events (team_id, at DESC);
COMMENT ON TABLE audit_events IS 'Tamper-evident team audit chain; written only by TeamDO outbox drains.';
