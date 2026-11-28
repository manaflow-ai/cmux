-- PlanetScale `cmux-next`: projections written only by the API Worker's outbox
-- drains. Every row carries the (source_stream, source_seq) of the owner event
-- that produced it; upserts never move a row backwards.

CREATE TABLE users (
  id             text PRIMARY KEY,
  stack_user_id  text NOT NULL UNIQUE,
  email          text,
  display_name   text NOT NULL,
  personal_team  text NOT NULL,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE teams (
  id             text PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('personal', 'stack')),
  stack_team_id  text UNIQUE,
  display_name   text NOT NULL,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  team_id        text NOT NULL,
  user_id        text NOT NULL,
  role           text NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (team_id, user_id)
);
CREATE INDEX memberships_user ON memberships (user_id);

CREATE TABLE installs (
  id             text PRIMARY KEY,
  user_id        text NOT NULL,
  device_id      text NOT NULL,
  kind           text NOT NULL,
  name           text NOT NULL,
  device_name    text NOT NULL,
  platform       text NOT NULL,
  thumbprint     text NOT NULL,
  grant_id       text NOT NULL,
  created_at     timestamptz NOT NULL,
  revoked_at     timestamptz,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX installs_user ON installs (user_id);

CREATE TABLE hosts (
  id             text PRIMARY KEY,
  team_id        text NOT NULL,
  owner_user     text NOT NULL,
  enrolled_by    text NOT NULL,
  name           text NOT NULL,
  platform       text NOT NULL,
  enrolled_at    timestamptz NOT NULL,
  deleted_at     timestamptz,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX hosts_team ON hosts (team_id) WHERE deleted_at IS NULL;
