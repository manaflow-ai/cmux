-- phase: expand
-- Integration connections (spec integrations.md): projection of each team's
-- ConnectionDO for listing and admin. No credential, token or provider payload
-- is ever written here.

CREATE TABLE connections (
  id                text PRIMARY KEY,
  team_id           text NOT NULL,
  created_by        text NOT NULL,
  provider          text NOT NULL,
  account_key       text,
  account_name      text,
  scopes_requested  jsonb NOT NULL,
  scopes_granted    jsonb NOT NULL,
  status            text NOT NULL,
  sharing           text NOT NULL,
  created_at        timestamptz NOT NULL,
  updated_at        timestamptz NOT NULL,
  source_stream     text NOT NULL,
  source_seq        bigint NOT NULL
);
CREATE INDEX connections_team ON connections (team_id);
CREATE INDEX connections_account ON connections (account_key) WHERE account_key IS NOT NULL;
