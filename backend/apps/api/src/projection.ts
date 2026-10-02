import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"

/**
 * Projection writes into PlanetScale `cmux-next`. A DO never writes Postgres in
 * its request path: it commits outbox rows with the op, and this drain applies
 * them with upserts guarded by `(source_stream, source_seq)`, so a replayed or
 * reordered batch never moves a row backwards (the DO stays the single writer).
 */
export const projectionStatements: Record<string, (p: Record<string, unknown>, stream: string, seq: number) => [string, Array<unknown>]> = {
  "user.upsert": (p, stream, seq) => [
    `INSERT INTO users (id, stack_user_id, email, display_name, personal_team, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, now())
     ON CONFLICT (id) DO UPDATE SET stack_user_id = excluded.stack_user_id, email = excluded.email, display_name = excluded.display_name,
       personal_team = excluded.personal_team, source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE users.source_seq < excluded.source_seq`,
    [p.id, p.stack_user_id, p.email ?? null, p.display_name, p.personal_team, stream, seq]
  ],
  "install.upsert": (p, stream, seq) => [
    `INSERT INTO installs (id, user_id, device_id, kind, name, device_name, platform, thumbprint, grant_id, created_at, revoked_at, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, to_timestamp($10 / 1000.0), CASE WHEN $11::bigint IS NULL THEN NULL ELSE to_timestamp($11 / 1000.0) END, $12, $13, now())
     ON CONFLICT (id) DO UPDATE SET name = excluded.name, device_name = excluded.device_name, revoked_at = excluded.revoked_at,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE installs.source_seq < excluded.source_seq`,
    [p.id, p.user, p.device, p.kind, p.name, p.device_name, p.platform, p.thumbprint, p.grant, p.created_at, p.revoked_at ?? null, stream, seq]
  ],
  "team.upsert": (p, stream, seq) => [
    `INSERT INTO teams (id, kind, display_name, source_stream, source_seq, updated_at) VALUES ($1, $2, $3, $4, $5, now())
     ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, display_name = excluded.display_name, source_stream = excluded.source_stream,
       source_seq = excluded.source_seq, updated_at = now()
     WHERE teams.source_seq < excluded.source_seq`,
    [p.id, p.kind, p.display_name, stream, seq]
  ],
  "membership.upsert": (p, stream, seq) => [
    `INSERT INTO memberships (team_id, user_id, role, source_stream, source_seq, updated_at) VALUES ($1, $2, $3, $4, $5, now())
     ON CONFLICT (team_id, user_id) DO UPDATE SET role = excluded.role, source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE memberships.source_seq < excluded.source_seq`,
    [p.team, p.user, p.role, stream, seq]
  ],
  "host.upsert": (p, stream, seq) => [
    `INSERT INTO hosts (id, team_id, owner_user, enrolled_by, name, platform, enrolled_at, deleted_at, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7 / 1000.0), NULL, $8, $9, now())
     ON CONFLICT (id) DO UPDATE SET name = excluded.name, platform = excluded.platform, deleted_at = NULL,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE hosts.source_seq < excluded.source_seq`,
    [p.id, p.team, p.owner_user, p.enrolled_by, p.name, p.platform, p.enrolled_at, stream, seq]
  ],
  "automation.upsert": (p, stream, seq) => [
    `INSERT INTO automations (id, team_id, name, enabled, version, definition, created_by, created_at, updated_at, next_run_at, deleted_at, source_stream, source_seq)
     VALUES ($1, $2, $3, $4, $5, $6, $7, to_timestamp($8 / 1000.0), to_timestamp($9 / 1000.0),
       CASE WHEN $10::bigint IS NULL THEN NULL ELSE to_timestamp($10 / 1000.0) END, NULL, $11, $12)
     ON CONFLICT (id) DO UPDATE SET name = excluded.name, enabled = excluded.enabled, version = excluded.version, definition = excluded.definition,
       updated_at = excluded.updated_at, next_run_at = excluded.next_run_at, deleted_at = NULL,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq
     WHERE automations.source_seq < excluded.source_seq`,
    [p.id, p.owner, p.name, p.enabled, p.version, JSON.stringify(p), p.created_by, p.created_at, p.updated_at, p.next_run_at ?? null, stream, seq]
  ],
  "automation.delete": (p, stream, seq) => [
    `UPDATE automations SET deleted_at = now(), source_stream = $2, source_seq = $3 WHERE id = $1 AND source_seq < $3`,
    [p.id, stream, seq]
  ],
  "automation_run.upsert": (p, stream, seq) => {
    const trigger = p.trigger as { type: string }
    const ts = (v: unknown) => (typeof v === "number" ? v : null)
    return [
      `INSERT INTO automation_runs (id, team_id, automation_id, automation_version, trigger_type, trigger, state, step, error, outcome, created_at, started_at, finished_at, source_stream, source_seq, updated_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, to_timestamp($11 / 1000.0),
         CASE WHEN $12::bigint IS NULL THEN NULL ELSE to_timestamp($12 / 1000.0) END,
         CASE WHEN $13::bigint IS NULL THEN NULL ELSE to_timestamp($13 / 1000.0) END, $14, $15, now())
       ON CONFLICT (id) DO UPDATE SET state = excluded.state, step = excluded.step, error = excluded.error, outcome = excluded.outcome,
         started_at = excluded.started_at, finished_at = excluded.finished_at, source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
       WHERE automation_runs.source_seq < excluded.source_seq`,
      [
        p.id, p.owner, p.automation, p.automation_version, trigger.type, JSON.stringify(p.trigger), p.state, p.step,
        p.error == null ? null : JSON.stringify(p.error), p.outcome == null ? null : JSON.stringify(p.outcome),
        p.created_at, ts(p.started_at), ts(p.finished_at), stream, seq
      ]
    ]
  },
  "connection.upsert": (p, stream, seq) => {
    const account = p.account as { key?: string; name?: string } | null
    return [
      `INSERT INTO connections (id, team_id, created_by, provider, account_key, account_name, scopes_requested, scopes_granted, status, sharing, created_at, updated_at, source_stream, source_seq)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, to_timestamp($11 / 1000.0), to_timestamp($12 / 1000.0), $13, $14)
       ON CONFLICT (id) DO UPDATE SET account_key = excluded.account_key, account_name = excluded.account_name, scopes_granted = excluded.scopes_granted,
         status = excluded.status, sharing = excluded.sharing, updated_at = excluded.updated_at, source_stream = excluded.source_stream, source_seq = excluded.source_seq
       WHERE connections.source_seq < excluded.source_seq`,
      [
        p.id, p.owner, p.created_by, p.provider, account?.key ?? null, account?.name ?? null,
        JSON.stringify(p.scopes_requested ?? []), JSON.stringify(p.scopes_granted ?? []), p.status, p.sharing, p.created_at, p.updated_at, stream, seq
      ]
    ]
  },
  // App store (0005_app_store.sql). AppDO writes apps + app_versions; UserDO/TeamDO write app_installs.
  "app.upsert": (p, stream, seq) => {
    const pub = p.publisher as { name: string; github_owner: string; verified: boolean }
    return [
      `INSERT INTO apps (id, publisher, publisher_name, publisher_verified, publisher_team, repository, name, description, categories, tier, latest_version, created_at, updated_at, source_stream, source_seq)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, to_timestamp($12 / 1000.0), to_timestamp($13 / 1000.0), $14, $15)
       ON CONFLICT (id) DO UPDATE SET publisher_name = excluded.publisher_name, publisher_verified = excluded.publisher_verified, publisher_team = excluded.publisher_team,
         repository = excluded.repository, name = excluded.name, description = excluded.description, categories = excluded.categories, tier = excluded.tier,
         latest_version = excluded.latest_version, updated_at = excluded.updated_at, source_stream = excluded.source_stream, source_seq = excluded.source_seq
       WHERE apps.source_seq < excluded.source_seq`,
      [p.id, pub.github_owner, pub.name, pub.verified, p.publisher_team, p.repository, p.name, p.description, p.categories ?? [], p.tier, p.latest_version ?? null, p.created_at, p.updated_at, stream, seq]
    ]
  },
  "app_version.upsert": (p, stream, seq) => [
    // The manifest is written once (submit); a yank row carries none and keeps the stored one.
    `INSERT INTO app_versions (app_id, version, tag, bundle_url, bundle_sha256, attestation_digest, manifest, scopes, optional_scopes, engines, published_by, published_at, yanked_at, yank_reason, source_stream, source_seq)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, to_timestamp($12 / 1000.0), CASE WHEN $13::bigint IS NULL THEN NULL ELSE to_timestamp($13 / 1000.0) END, $14, $15, $16)
     ON CONFLICT (app_id, version) DO UPDATE SET yanked_at = excluded.yanked_at, yank_reason = excluded.yank_reason,
       manifest = COALESCE(excluded.manifest, app_versions.manifest), source_stream = excluded.source_stream, source_seq = excluded.source_seq
     WHERE app_versions.source_seq < excluded.source_seq`,
    [
      p.app, p.version, p.tag, p.bundle_url, p.bundle_sha256, p.attestation_digest ?? null, p.manifest === undefined ? null : JSON.stringify(p.manifest),
      Object.keys((p.scopes ?? {}) as object), Object.keys((p.optional_scopes ?? {}) as object), (p.engines as { cmux: string }).cmux,
      p.published_by, p.published_at, p.yanked_at ?? null, p.yank_reason ?? null, stream, seq
    ]
  ],
  "app_install.upsert": (p, stream, seq) => [
    `INSERT INTO app_installs (app_id, scope_kind, scope_id, version, installed_at, removed_at, hidden, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, to_timestamp($5 / 1000.0), CASE WHEN $6::bigint IS NULL THEN NULL ELSE to_timestamp($6 / 1000.0) END, $9, $7, $8, now())
     ON CONFLICT (app_id, scope_kind, scope_id) DO UPDATE SET version = excluded.version, installed_at = excluded.installed_at, removed_at = excluded.removed_at,
       hidden = excluded.hidden, source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE app_installs.source_seq < excluded.source_seq`,
    [p.app, p.scope_kind, p.scope_id, p.version, p.installed_at, p.removed_at ?? null, stream, seq, p.hidden === true]
  ],
  "host.delete": (p, stream, seq) => [
    `UPDATE hosts SET deleted_at = now(), source_stream = $2, source_seq = $3, updated_at = now() WHERE id = $1 AND source_seq < $3`,
    [p.id, stream, seq]
  ]
}

export const drainOutbox = async (env: Env, stream: string, rows: ReadonlyArray<OutboxRow>): Promise<void> => {
  if (!env.HYPERDRIVE) throw new Error("HYPERDRIVE binding missing")
  // Loaded on first drain only: keeps pg (CommonJS, node:net) off the request path and out of unit tests.
  const { default: pg } = await import("pg")
  const client = new pg.Client({ connectionString: env.HYPERDRIVE.connectionString })
  await client.connect()
  try {
    await client.query("BEGIN")
    for (const row of rows) {
      const make = projectionStatements[row.kind]
      // An unknown kind (newer writer than this drain) must not block every later row.
      if (!make) {
        console.error(JSON.stringify({ msg: "outbox row skipped: no projection", stream, seq: row.seq, kind: row.kind }))
        continue
      }
      const [text, values] = make(row.payload as Record<string, unknown>, stream, row.seq)
      await client.query(text, values)
    }
    await client.query("COMMIT")
  } catch (e) {
    await client.query("ROLLBACK").catch(() => undefined)
    throw e
  } finally {
    await client.end()
  }
}
