import type { OutboxRow } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { pgSafe } from "./text-safe.ts"

/**
 * Projection writes into PlanetScale `cmux-next`. A DO never writes Postgres in
 * its request path: it commits outbox rows with the op, and this drain applies
 * them with upserts guarded by `(source_stream, source_seq)`, so a replayed or
 * reordered batch never moves a row backwards (the DO stays the single writer).
 */
const statements: Record<string, (p: Record<string, unknown>, stream: string, seq: number) => [string, Array<unknown>]> = {
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
  "audit.append": (p, stream, seq) => [
    `INSERT INTO audit_events (team_id, n, op, actor, on_behalf_of, transaction, at, summary, detail, prev_hash, hash, source_stream, source_seq)
     VALUES ($1, $2, $3, $4, $5, $6, to_timestamp($7 / 1000.0), $8, $9, $10, $11, $12, $13)
     ON CONFLICT DO NOTHING`,
    [p.team, p.n, p.op, p.actor, p.on_behalf_of ?? null, p.tx, p.at, p.summary, JSON.stringify(p.detail ?? null), p.prev_hash, p.hash, stream, seq]
  ],
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
  // Home messaging (home-messaging.md section 7; migration 0006). Payloads are home-core's
  // conversationProjection, participantProjection, inviteProjection and SearchRow.
  "home.conversation.upsert": (p, stream, seq) => [
    `INSERT INTO home_conversations (id, kind, team_id, title, created_by, created_at, last_seq, last_at, participant_count, state, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, now())
     ON CONFLICT (id) DO UPDATE SET kind = excluded.kind, team_id = excluded.team_id, title = excluded.title, last_seq = excluded.last_seq,
       last_at = excluded.last_at, participant_count = excluded.participant_count, state = excluded.state,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE home_conversations.source_seq < excluded.source_seq`,
    [p.id, p.kind, p.team_id ?? null, p.title ?? null, p.created_by ?? null, p.created_at, p.last_seq, p.last_at, p.participant_count, p.state, stream, seq]
  ],
  // home-core sends joined_at only for a new or rejoined participant; otherwise the stored one stays.
  "home.participant.upsert": (p, stream, seq) => [
    `INSERT INTO home_participants (conversation_id, participant_id, kind, visible_from_seq, joined_at, left_at, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, COALESCE($5::timestamptz, now()), $6, $7, $8, now())
     ON CONFLICT (conversation_id, participant_id) DO UPDATE SET kind = excluded.kind, visible_from_seq = excluded.visible_from_seq,
       joined_at = COALESCE($5::timestamptz, home_participants.joined_at), left_at = excluded.left_at,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE home_participants.source_seq < excluded.source_seq`,
    [p.conversation_id, p.participant_id, p.kind, p.visible_from_seq ?? 0, p.joined_at ?? null, p.left_at ?? null, stream, seq]
  ],
  "home.message.upsert": (p, stream, seq) => [
    `INSERT INTO home_message_search (conversation_id, seq, message_id, author_id, author_kind, created_at, edited_at, body, source_stream, source_seq)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
     ON CONFLICT (conversation_id, seq) DO UPDATE SET message_id = excluded.message_id, author_id = excluded.author_id,
       author_kind = excluded.author_kind, edited_at = excluded.edited_at, body = excluded.body,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq
     WHERE home_message_search.source_seq < excluded.source_seq`,
    [p.conversation_id, p.seq, p.message_id, p.author_id, p.author_kind, p.created_at, p.edited_at ?? null, p.body, stream, seq]
  ],
  // Retraction and retention: the row goes unless a newer write already replaced it.
  "home.message.delete": (p, stream, seq) => [
    `DELETE FROM home_message_search WHERE conversation_id = $1 AND seq = $2 AND source_stream = $3 AND source_seq <= $4`,
    [p.conversation_id, p.seq, stream, seq]
  ],
  "home.invite.upsert": (p, stream, seq) => [
    `INSERT INTO home_invites (id, conversation_id, invited_by, address_id, channel, status, delivery_state, copy_variant, created_at, expires_at, accepted_by, accepted_at, source_stream, source_seq, updated_at)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, now())
     ON CONFLICT (id) DO UPDATE SET status = excluded.status, delivery_state = excluded.delivery_state, expires_at = excluded.expires_at,
       accepted_by = excluded.accepted_by, accepted_at = excluded.accepted_at,
       source_stream = excluded.source_stream, source_seq = excluded.source_seq, updated_at = now()
     WHERE home_invites.source_seq < excluded.source_seq`,
    [p.id, p.conversation_id, p.invited_by, p.address_id, p.channel, p.status, p.delivery_state, p.copy_variant, p.created_at, p.expires_at, p.accepted_by ?? null, p.accepted_at ?? null, stream, seq]
  ],
  "host.delete": (p, stream, seq) => [
    `UPDATE hosts SET deleted_at = now(), source_stream = $2, source_seq = $3, updated_at = now() WHERE id = $1 AND source_seq < $3`,
    [p.id, stream, seq]
  ]
}

/** The SQL for one outbox row, or undefined for a kind this drain does not know. */
export const projectionStatement = (kind: string, payload: unknown, stream: string, seq: number): [string, Array<unknown>] | undefined => {
  const make = statements[kind]
  return make ? make(pgSafe(payload) as Record<string, unknown>, stream, seq) : undefined
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
      const statement = projectionStatement(row.kind, row.payload, stream, row.seq)
      // An unknown kind (newer writer than this drain) must not block every later row.
      if (!statement) {
        console.error(JSON.stringify({ msg: "outbox row skipped: no projection", stream, seq: row.seq, kind: row.kind }))
        continue
      }
      await client.query(statement[0], statement[1])
    }
    await client.query("COMMIT")
  } catch (e) {
    await client.query("ROLLBACK").catch(() => undefined)
    throw e
  } finally {
    await client.end()
  }
}
