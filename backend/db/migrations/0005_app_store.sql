-- phase: expand
-- App store (spec app-platform.md section 11, D46): read projections of AppDO
-- (apps, app_versions) and of UserDO/TeamDO installs (app_installs, counts and
-- versions only, never granted scopes). First-party apps installed by default
-- have no rows until a user installs them explicitly. Each row has exactly one writer stream,
-- guarded by source_stream/source_seq like 0001. Search is a generated
-- tsvector with a GIN index and word-prefix tsquery (no trigram index).

-- Publisher identity (GitHub owner verified through the GitHub App or OAuth),
-- written by the publishing team's TeamDO once verification exists. No writer yet.
CREATE TABLE app_publishers (
  id             text PRIMARY KEY,
  team_id        text NOT NULL,
  github_owner   text NOT NULL,
  verified_at    timestamptz,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX app_publishers_github_owner ON app_publishers (lower(github_owner));
CREATE INDEX app_publishers_team ON app_publishers (team_id);

CREATE TABLE apps (
  id                  text PRIMARY KEY,
  publisher           text NOT NULL,
  publisher_name      text NOT NULL,
  publisher_verified  boolean NOT NULL DEFAULT false,
  publisher_team      text NOT NULL,
  repository          text NOT NULL,
  name                text NOT NULL,
  description         text NOT NULL,
  categories          text[] NOT NULL DEFAULT '{}',
  tier                text NOT NULL CHECK (tier IN ('first-party', 'verified', 'unverified')),
  icon_url            text,
  latest_version      text,
  created_at          timestamptz NOT NULL,
  updated_at          timestamptz NOT NULL,
  search              tsvector GENERATED ALWAYS AS (
                        setweight(to_tsvector('simple', name), 'A') ||
                        setweight(to_tsvector('simple', replace(id, '/', ' ')), 'A') ||
                        setweight(to_tsvector('simple', publisher_name), 'B') ||
                        setweight(to_tsvector('simple', description), 'C')
                      ) STORED,
  source_stream       text NOT NULL,
  source_seq          bigint NOT NULL
);
CREATE INDEX apps_search ON apps USING gin (search);
CREATE INDEX apps_categories ON apps USING gin (categories);
CREATE INDEX apps_publisher ON apps (publisher);

CREATE TABLE app_versions (
  app_id              text NOT NULL,
  version             text NOT NULL,
  tag                 text NOT NULL,
  commit_sha          text,
  bundle_url          text NOT NULL,
  bundle_sha256       text NOT NULL,
  attestation_digest  text,
  manifest            jsonb,
  scopes              text[] NOT NULL,
  optional_scopes     text[] NOT NULL DEFAULT '{}',
  engines             text NOT NULL,
  published_by        text NOT NULL,
  published_at        timestamptz NOT NULL,
  yanked_at           timestamptz,
  yank_reason         text,
  source_stream       text NOT NULL,
  source_seq          bigint NOT NULL,
  PRIMARY KEY (app_id, version)
);

CREATE TABLE app_installs (
  app_id         text NOT NULL,
  scope_kind     text NOT NULL CHECK (scope_kind IN ('user', 'team')),
  scope_id       text NOT NULL,
  version        text NOT NULL,
  installed_at   timestamptz NOT NULL,
  removed_at     timestamptz,
  -- Hidden by the user (still running; clients drop its entries). Not disable, not remove.
  hidden         boolean NOT NULL DEFAULT false,
  source_stream  text NOT NULL,
  source_seq     bigint NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (app_id, scope_kind, scope_id)
);
CREATE INDEX app_installs_active ON app_installs (app_id) WHERE removed_at IS NULL;
CREATE INDEX app_installs_scope ON app_installs (scope_kind, scope_id);
