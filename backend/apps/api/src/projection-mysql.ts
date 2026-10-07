import { auditEvents, automationRuns, automations, connections, homeConversations, homeInvites, homeMessageSearch, homeParticipants, hosts, installs, memberships, teams, users } from "@cmux/db/schema-mysql"
import { and, eq, lt, lte, sql, type SQL } from "drizzle-orm"
import type { MySqlColumn } from "drizzle-orm/mysql-core"
import { drizzle } from "drizzle-orm/mysql-proxy"
import { pgSafe } from "./text-safe.ts"

/**
 * Projection statements for PlanetScale MySQL (plans/cmux-next/state-placement.md 4.1), the same
 * kinds and payloads as the Postgres drain (projection.ts, projection-drizzle.ts). Every upsert keeps
 * the single-writer guard: a row changes only when the incoming source_seq is newer than the stored
 * one. MySQL has no conditional ON CONFLICT, so each assignment is `col = IF(cond, VALUES(col), col)`.
 * MySQL evaluates the assignments left to right and later ones see values already assigned, and
 * Drizzle renders the SET list in table column order (not ours), so the condition must not depend on
 * whether source_seq was already updated: `source_seq <= VALUES(source_seq)`. For an older incoming
 * seq it is false everywhere; for a newer one it is true before and after source_seq moves (then
 * equal). Re-applying the same seq rewrites the same values, which is harmless: one seq is one op.
 */
// mysql-proxy only renders SQL; the drain runs it on its own mysql2 connection.
const db = drizzle(async () => ({ rows: [] }))
type Payload = Record<string, unknown>
export type Statement = [string, Array<unknown>]

/** A UTC `datetime(3)` literal from epoch ms or an ISO string; null stays null. */
export const dt = (v: unknown): string | null => {
  if (v === undefined || v === null) return null
  const ms = typeof v === "number" ? v : Date.parse(String(v))
  if (!Number.isFinite(ms)) throw new Error(`invalid time ${String(v)}`)
  return new Date(ms).toISOString().replace("T", " ").replace("Z", "")
}
const text = (v: unknown): string | null => (v === undefined || v === null ? null : String(v))
const render = (q: { toSQL(): { sql: string; params: Array<unknown> } }): Statement => {
  const { sql: s, params } = q.toSQL()
  return [s, params]
}
const col = (c: MySqlColumn) => sql.raw(`\`${c.name}\``)
const incoming = (c: MySqlColumn) => sql.raw(`VALUES(\`${c.name}\`)`)
const newer = sql.raw("`source_seq` <= VALUES(`source_seq`)")

/**
 * The guarded SET list: each listed column takes the incoming value only when the row is newer;
 * `updated_at` (when the table has it) moves to now under the same condition; source_seq becomes
 * the greater of the two. `keep` columns are assigned their stored value explicitly (for a column a
 * payload may omit, such as home_participants.joined_at).
 */
export const guardedSet = (table: { sourceStream: MySqlColumn; sourceSeq: MySqlColumn; updatedAt?: MySqlColumn }, columns: Record<string, MySqlColumn>, overrides: Record<string, SQL> = {}): Record<string, SQL> => {
  const set: Record<string, SQL> = {}
  for (const [key, c] of Object.entries(columns)) set[key] = overrides[key] ?? sql`IF(${newer}, ${incoming(c)}, ${col(c)})`
  if (table.updatedAt) set.updatedAt = sql`IF(${newer}, CURRENT_TIMESTAMP(3), ${col(table.updatedAt)})`
  set.sourceStream = sql`IF(${newer}, ${incoming(table.sourceStream)}, ${col(table.sourceStream)})`
  set.sourceSeq = sql`GREATEST(${col(table.sourceSeq)}, ${incoming(table.sourceSeq)})`
  return set
}

const statements: Record<string, (p: Payload, stream: string, seq: number) => Statement> = {
  "user.upsert": (p, stream, seq) =>
    render(
      db.insert(users)
        .values({ id: String(p.id), stackUserId: String(p.stack_user_id), email: text(p.email), displayName: String(p.display_name), personalTeam: String(p.personal_team), sourceStream: stream, sourceSeq: seq })
        .onDuplicateKeyUpdate({ set: guardedSet(users, { stackUserId: users.stackUserId, email: users.email, displayName: users.displayName, personalTeam: users.personalTeam }) })
    ),
  "install.upsert": (p, stream, seq) =>
    render(
      db.insert(installs)
        .values({
          id: String(p.id), userId: String(p.user), deviceId: String(p.device), kind: String(p.kind), name: String(p.name), deviceName: String(p.device_name), platform: String(p.platform),
          thumbprint: String(p.thumbprint), grantId: String(p.grant), createdAt: dt(p.created_at)!, revokedAt: dt(p.revoked_at), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({ set: guardedSet(installs, { name: installs.name, deviceName: installs.deviceName, revokedAt: installs.revokedAt }) })
    ),
  "team.upsert": (p, stream, seq) =>
    render(
      db.insert(teams)
        .values({ id: String(p.id), kind: String(p.kind), displayName: String(p.display_name), sourceStream: stream, sourceSeq: seq })
        .onDuplicateKeyUpdate({ set: guardedSet(teams, { kind: teams.kind, displayName: teams.displayName }) })
    ),
  "membership.upsert": (p, stream, seq) =>
    render(
      db.insert(memberships)
        .values({ teamId: String(p.team), userId: String(p.user), role: String(p.role), sourceStream: stream, sourceSeq: seq })
        .onDuplicateKeyUpdate({ set: guardedSet(memberships, { role: memberships.role }) })
    ),
  "host.upsert": (p, stream, seq) =>
    render(
      db.insert(hosts)
        .values({ id: String(p.id), teamId: String(p.team), ownerUser: String(p.owner_user), enrolledBy: String(p.enrolled_by), name: String(p.name), platform: String(p.platform), enrolledAt: dt(p.enrolled_at)!, deletedAt: null, sourceStream: stream, sourceSeq: seq })
        .onDuplicateKeyUpdate({ set: guardedSet(hosts, { name: hosts.name, platform: hosts.platform, deletedAt: hosts.deletedAt }) })
    ),
  "host.delete": (p, stream, seq) =>
    render(db.update(hosts).set({ deletedAt: sql`CURRENT_TIMESTAMP(3)` as never, sourceStream: stream, sourceSeq: seq, updatedAt: sql`CURRENT_TIMESTAMP(3)` as never }).where(and(eq(hosts.id, String(p.id)), lt(hosts.sourceSeq, seq)))),
  "automation.upsert": (p, stream, seq) =>
    render(
      db.insert(automations)
        .values({
          id: String(p.id), teamId: String(p.owner), name: String(p.name), enabled: Boolean(p.enabled), version: Number(p.version), definition: p, createdBy: String(p.created_by),
          createdAt: dt(p.created_at)!, updatedAt: dt(p.updated_at)!, nextRunAt: dt(p.next_run_at), deletedAt: null, sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(
            { sourceStream: automations.sourceStream, sourceSeq: automations.sourceSeq },
            { name: automations.name, enabled: automations.enabled, version: automations.version, definition: automations.definition, updatedAt: automations.updatedAt, nextRunAt: automations.nextRunAt, deletedAt: automations.deletedAt }
          )
        })
    ),
  "automation.delete": (p, stream, seq) =>
    render(db.update(automations).set({ deletedAt: sql`CURRENT_TIMESTAMP(3)` as never, sourceStream: stream, sourceSeq: seq }).where(and(eq(automations.id, String(p.id)), lt(automations.sourceSeq, seq)))),
  "automation_run.upsert": (p, stream, seq) =>
    render(
      db.insert(automationRuns)
        .values({
          id: String(p.id), teamId: String(p.owner), automationId: String(p.automation), automationVersion: Number(p.automation_version), triggerType: String((p.trigger as { type: string }).type),
          trigger: p.trigger, state: String(p.state), step: Number(p.step), error: p.error ?? null, outcome: p.outcome ?? null,
          createdAt: dt(p.created_at)!, startedAt: dt(p.started_at), finishedAt: dt(p.finished_at), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(automationRuns, { state: automationRuns.state, step: automationRuns.step, error: automationRuns.error, outcome: automationRuns.outcome, startedAt: automationRuns.startedAt, finishedAt: automationRuns.finishedAt })
        })
    ),
  // Append-only: a repeated (team, n) or (source_stream, source_seq) changes nothing. Not INSERT
  // IGNORE, which would also hide truncation and type errors.
  "audit.append": (p, stream, seq) =>
    render(
      db.insert(auditEvents)
        .values({
          teamId: String(p.team), n: Number(p.n), op: String(p.op), actor: String(p.actor), onBehalfOf: text(p.on_behalf_of), transaction: String(p.tx), at: dt(p.at)!,
          summary: String(p.summary), detail: p.detail ?? null, prevHash: String(p.prev_hash), hash: String(p.hash), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({ set: { teamId: sql.raw("`team_id`") } })
    ),
  "connection.upsert": (p, stream, seq) => {
    const account = p.account as { key?: string; name?: string } | null
    return render(
      db.insert(connections)
        .values({
          id: String(p.id), teamId: String(p.owner), createdBy: String(p.created_by), provider: String(p.provider), accountKey: account?.key ?? null, accountName: account?.name ?? null,
          scopesRequested: p.scopes_requested ?? [], scopesGranted: p.scopes_granted ?? [], status: String(p.status), sharing: String(p.sharing),
          createdAt: dt(p.created_at)!, updatedAt: dt(p.updated_at)!, sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(
            { sourceStream: connections.sourceStream, sourceSeq: connections.sourceSeq },
            { accountKey: connections.accountKey, accountName: connections.accountName, scopesGranted: connections.scopesGranted, status: connections.status, sharing: connections.sharing, updatedAt: connections.updatedAt }
          )
        })
    )
  },
  "home.conversation.upsert": (p, stream, seq) =>
    render(
      db.insert(homeConversations)
        .values({
          id: String(p.id), kind: String(p.kind), teamId: text(p.team_id), title: text(p.title), createdBy: text(p.created_by), createdAt: dt(p.created_at)!, lastSeq: Number(p.last_seq),
          lastAt: dt(p.last_at)!, participantCount: Number(p.participant_count), state: String(p.state), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(homeConversations, {
            kind: homeConversations.kind, teamId: homeConversations.teamId, title: homeConversations.title, lastSeq: homeConversations.lastSeq, lastAt: homeConversations.lastAt,
            participantCount: homeConversations.participantCount, state: homeConversations.state
          })
        })
    ),
  // home-core sends joined_at only for a new or rejoined participant; otherwise the stored one stays.
  "home.participant.upsert": (p, stream, seq) => {
    const joined = dt(p.joined_at)
    return render(
      db.insert(homeParticipants)
        .values({
          conversationId: String(p.conversation_id), participantId: String(p.participant_id), kind: String(p.kind), visibleFromSeq: Number(p.visible_from_seq ?? 0),
          joinedAt: (joined ?? sql`CURRENT_TIMESTAMP(3)`) as never, leftAt: dt(p.left_at), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(
            homeParticipants,
            { kind: homeParticipants.kind, visibleFromSeq: homeParticipants.visibleFromSeq, joinedAt: homeParticipants.joinedAt, leftAt: homeParticipants.leftAt },
            joined === null ? { joinedAt: sql.raw("`joined_at`") } : {}
          )
        })
    )
  },
  "home.invite.upsert": (p, stream, seq) =>
    render(
      db.insert(homeInvites)
        .values({
          id: String(p.id), conversationId: String(p.conversation_id), invitedBy: String(p.invited_by), addressId: String(p.address_id), channel: String(p.channel), status: String(p.status),
          deliveryState: String(p.delivery_state), copyVariant: String(p.copy_variant), createdAt: dt(p.created_at)!, expiresAt: dt(p.expires_at)!, acceptedBy: text(p.accepted_by),
          acceptedAt: dt(p.accepted_at), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(homeInvites, { status: homeInvites.status, deliveryState: homeInvites.deliveryState, expiresAt: homeInvites.expiresAt, acceptedBy: homeInvites.acceptedBy, acceptedAt: homeInvites.acceptedAt })
        })
    ),
  "home.message.upsert": (p, stream, seq) =>
    render(
      db.insert(homeMessageSearch)
        .values({
          conversationId: String(p.conversation_id), seq: Number(p.seq), messageId: String(p.message_id), authorId: String(p.author_id), authorKind: String(p.author_kind),
          createdAt: dt(p.created_at)!, editedAt: dt(p.edited_at), body: String(p.body), sourceStream: stream, sourceSeq: seq
        })
        .onDuplicateKeyUpdate({
          set: guardedSet(
            { sourceStream: homeMessageSearch.sourceStream, sourceSeq: homeMessageSearch.sourceSeq },
            { messageId: homeMessageSearch.messageId, authorId: homeMessageSearch.authorId, authorKind: homeMessageSearch.authorKind, editedAt: homeMessageSearch.editedAt, body: homeMessageSearch.body }
          )
        })
    ),
  "home.message.delete": (p, stream, seq) =>
    render(
      db.delete(homeMessageSearch).where(and(eq(homeMessageSearch.conversationId, String(p.conversation_id)), eq(homeMessageSearch.seq, Number(p.seq)), eq(homeMessageSearch.sourceStream, stream), lte(homeMessageSearch.sourceSeq, seq)))
    ),
  // Retention (conversation.sweep): every row of the conversation up to `seq`, one statement per sweep.
  "home.message.delete_through": (p, stream, seq) =>
    render(
      db.delete(homeMessageSearch).where(and(eq(homeMessageSearch.conversationId, String(p.conversation_id)), lte(homeMessageSearch.seq, Number(p.seq)), eq(homeMessageSearch.sourceStream, stream), lte(homeMessageSearch.sourceSeq, seq)))
    )
}

/** The MySQL statement for one outbox row, or undefined for a kind this drain does not know. */
export const projectionStatementMysql = (kind: string, payload: unknown, stream: string, seq: number): Statement | undefined => {
  const make = statements[kind]
  return make ? make(pgSafe(payload) as Payload, stream, seq) : undefined
}

/** The projection kinds both dialects must cover (a test compares them). */
export const mysqlProjectionKinds = (): Array<string> => Object.keys(statements)
