import { auditEvents, automationRuns, automations, connections, homeConversations, homeInvites, homeParticipants, hosts, installs, memberships, teams, users } from "@cmux/db/schema"
import { and, eq, lt, sql, type SQL } from "drizzle-orm"
import { drizzle } from "drizzle-orm/pg-proxy"
import type { PgTable } from "drizzle-orm/pg-core"

/**
 * Projection statements built with Drizzle (C-BATCH 2) from backend/db/schema. Every upsert keeps
 * the single-writer guard: the row changes only when the incoming (source_stream, source_seq)
 * is newer. The builder only renders SQL; the drain runs it on its own pg client.
 */
// pg-proxy keeps the pg driver (CommonJS, node:net) out of this module; queries are only rendered.
const db = drizzle(async () => ({ rows: [] }))
type Payload = Record<string, unknown>
type Statement = [string, Array<unknown>]

const iso = (ms: unknown): string | null => (typeof ms === "number" ? new Date(ms).toISOString() : null)
const text = (v: unknown): string | null => (v === undefined || v === null ? null : String(v))
const render = (q: { toSQL(): { sql: string; params: Array<unknown> } }): Statement => {
  const { sql: s, params } = q.toSQL()
  return [s, params]
}
/** `excluded.<column>` for an upsert's SET list. */
const ex = (column: { name: string }) => sql.raw(`excluded."${column.name}"`)
/** The guard: update only when the stored source_seq is older. */
const newer = (table: PgTable & { sourceSeq: unknown }) => lt((table as unknown as { sourceSeq: SQL }).sourceSeq as never, sql.raw(`excluded."source_seq"`) as never)
const now = sql`now()`

export const drizzleStatements: Record<string, (p: Payload, stream: string, seq: number) => Statement> = {
  "user.upsert": (p, stream, seq) =>
    render(
      db
        .insert(users)
        .values({ id: String(p.id), stackUserId: String(p.stack_user_id), email: text(p.email), displayName: String(p.display_name), personalTeam: String(p.personal_team), sourceStream: stream, sourceSeq: seq, updatedAt: now as never })
        .onConflictDoUpdate({
          target: users.id,
          set: { stackUserId: ex(users.stackUserId), email: ex(users.email), displayName: ex(users.displayName), personalTeam: ex(users.personalTeam), sourceStream: ex(users.sourceStream), sourceSeq: ex(users.sourceSeq), updatedAt: now },
          setWhere: newer(users)
        })
    ),
  "install.upsert": (p, stream, seq) =>
    render(
      db
        .insert(installs)
        .values({
          id: String(p.id), userId: String(p.user), deviceId: String(p.device), kind: String(p.kind), name: String(p.name), deviceName: String(p.device_name), platform: String(p.platform),
          thumbprint: String(p.thumbprint), grantId: String(p.grant), createdAt: iso(p.created_at)!, revokedAt: iso(p.revoked_at), sourceStream: stream, sourceSeq: seq, updatedAt: now as never
        })
        .onConflictDoUpdate({
          target: installs.id,
          set: { name: ex(installs.name), deviceName: ex(installs.deviceName), revokedAt: ex(installs.revokedAt), sourceStream: ex(installs.sourceStream), sourceSeq: ex(installs.sourceSeq), updatedAt: now },
          setWhere: newer(installs)
        })
    ),
  "team.upsert": (p, stream, seq) =>
    render(
      db
        .insert(teams)
        .values({ id: String(p.id), kind: String(p.kind), displayName: String(p.display_name), sourceStream: stream, sourceSeq: seq, updatedAt: now as never })
        .onConflictDoUpdate({
          target: teams.id,
          set: { kind: ex(teams.kind), displayName: ex(teams.displayName), sourceStream: ex(teams.sourceStream), sourceSeq: ex(teams.sourceSeq), updatedAt: now },
          setWhere: newer(teams)
        })
    ),
  "membership.upsert": (p, stream, seq) =>
    render(
      db
        .insert(memberships)
        .values({ teamId: String(p.team), userId: String(p.user), role: String(p.role), sourceStream: stream, sourceSeq: seq, updatedAt: now as never })
        .onConflictDoUpdate({
          target: [memberships.teamId, memberships.userId],
          set: { role: ex(memberships.role), sourceStream: ex(memberships.sourceStream), sourceSeq: ex(memberships.sourceSeq), updatedAt: now },
          setWhere: newer(memberships)
        })
    ),
  "host.upsert": (p, stream, seq) =>
    render(
      db
        .insert(hosts)
        .values({ id: String(p.id), teamId: String(p.team), ownerUser: String(p.owner_user), enrolledBy: String(p.enrolled_by), name: String(p.name), platform: String(p.platform), enrolledAt: iso(p.enrolled_at)!, deletedAt: null, sourceStream: stream, sourceSeq: seq, updatedAt: now as never })
        .onConflictDoUpdate({
          target: hosts.id,
          set: { name: ex(hosts.name), platform: ex(hosts.platform), deletedAt: sql`NULL`, sourceStream: ex(hosts.sourceStream), sourceSeq: ex(hosts.sourceSeq), updatedAt: now },
          setWhere: newer(hosts)
        })
    ),
  "host.delete": (p, stream, seq) => render(db.update(hosts).set({ deletedAt: now as never, sourceStream: stream, sourceSeq: seq, updatedAt: now as never }).where(and(eq(hosts.id, String(p.id)), lt(hosts.sourceSeq, seq)))),
  "automation.upsert": (p, stream, seq) =>
    render(
      db
        .insert(automations)
        .values({
          id: String(p.id), teamId: String(p.owner), name: String(p.name), enabled: Boolean(p.enabled), version: Number(p.version), definition: p as never, createdBy: String(p.created_by),
          createdAt: iso(p.created_at)!, updatedAt: iso(p.updated_at)!, nextRunAt: iso(p.next_run_at), deletedAt: null, sourceStream: stream, sourceSeq: seq
        })
        .onConflictDoUpdate({
          target: automations.id,
          set: {
            name: ex(automations.name), enabled: ex(automations.enabled), version: ex(automations.version), definition: ex(automations.definition), updatedAt: ex(automations.updatedAt),
            nextRunAt: ex(automations.nextRunAt), deletedAt: sql`NULL`, sourceStream: ex(automations.sourceStream), sourceSeq: ex(automations.sourceSeq)
          },
          setWhere: newer(automations)
        })
    ),
  "automation.delete": (p, stream, seq) => render(db.update(automations).set({ deletedAt: now as never, sourceStream: stream, sourceSeq: seq }).where(and(eq(automations.id, String(p.id)), lt(automations.sourceSeq, seq)))),
  "automation_run.upsert": (p, stream, seq) =>
    render(
      db
        .insert(automationRuns)
        .values({
          id: String(p.id), teamId: String(p.owner), automationId: String(p.automation), automationVersion: Number(p.automation_version), triggerType: String((p.trigger as { type: string }).type),
          trigger: p.trigger as never, state: String(p.state), step: Number(p.step), error: (p.error ?? null) as never, outcome: (p.outcome ?? null) as never,
          createdAt: iso(p.created_at)!, startedAt: iso(p.started_at), finishedAt: iso(p.finished_at), sourceStream: stream, sourceSeq: seq, updatedAt: now as never
        })
        .onConflictDoUpdate({
          target: automationRuns.id,
          set: {
            state: ex(automationRuns.state), step: ex(automationRuns.step), error: ex(automationRuns.error), outcome: ex(automationRuns.outcome), startedAt: ex(automationRuns.startedAt),
            finishedAt: ex(automationRuns.finishedAt), sourceStream: ex(automationRuns.sourceStream), sourceSeq: ex(automationRuns.sourceSeq), updatedAt: now
          },
          setWhere: newer(automationRuns)
        })
    ),
  "audit.append": (p, stream, seq) =>
    render(
      db
        .insert(auditEvents)
        .values({
          teamId: String(p.team), n: Number(p.n), op: String(p.op), actor: String(p.actor), onBehalfOf: text(p.on_behalf_of), transaction: String(p.tx), at: iso(p.at)!,
          summary: String(p.summary), detail: (p.detail ?? null) as never, prevHash: String(p.prev_hash), hash: String(p.hash), sourceStream: stream, sourceSeq: seq
        })
        .onConflictDoNothing()
    ),
  "connection.upsert": (p, stream, seq) => {
    const account = p.account as { key?: string; name?: string } | null
    return render(
      db
        .insert(connections)
        .values({
          id: String(p.id), teamId: String(p.owner), createdBy: String(p.created_by), provider: String(p.provider), accountKey: account?.key ?? null, accountName: account?.name ?? null,
          scopesRequested: (p.scopes_requested ?? []) as never, scopesGranted: (p.scopes_granted ?? []) as never, status: String(p.status), sharing: String(p.sharing),
          createdAt: iso(p.created_at)!, updatedAt: iso(p.updated_at)!, sourceStream: stream, sourceSeq: seq
        })
        .onConflictDoUpdate({
          target: connections.id,
          set: {
            accountKey: ex(connections.accountKey), accountName: ex(connections.accountName), scopesGranted: ex(connections.scopesGranted), status: ex(connections.status),
            sharing: ex(connections.sharing), updatedAt: ex(connections.updatedAt), sourceStream: ex(connections.sourceStream), sourceSeq: ex(connections.sourceSeq)
          },
          setWhere: newer(connections)
        })
    )
  },
  "home.conversation.upsert": (p, stream, seq) =>
    render(
      db
        .insert(homeConversations)
        .values({
          id: String(p.id), kind: String(p.kind), teamId: text(p.team_id), title: text(p.title), createdBy: text(p.created_by), createdAt: String(p.created_at), lastSeq: Number(p.last_seq),
          lastAt: String(p.last_at), participantCount: Number(p.participant_count), state: String(p.state), sourceStream: stream, sourceSeq: seq, updatedAt: now as never
        })
        .onConflictDoUpdate({
          target: homeConversations.id,
          set: {
            kind: ex(homeConversations.kind), teamId: ex(homeConversations.teamId), title: ex(homeConversations.title), lastSeq: ex(homeConversations.lastSeq), lastAt: ex(homeConversations.lastAt),
            participantCount: ex(homeConversations.participantCount), state: ex(homeConversations.state), sourceStream: ex(homeConversations.sourceStream), sourceSeq: ex(homeConversations.sourceSeq), updatedAt: now
          },
          setWhere: newer(homeConversations)
        })
    ),
  // home-core sends joined_at only for a new or rejoined participant; otherwise the stored one stays.
  "home.participant.upsert": (p, stream, seq) => {
    const joined = text(p.joined_at)
    return render(
      db
        .insert(homeParticipants)
        .values({
          conversationId: String(p.conversation_id), participantId: String(p.participant_id), kind: String(p.kind), visibleFromSeq: Number(p.visible_from_seq ?? 0),
          joinedAt: (joined ?? now) as never, leftAt: text(p.left_at), sourceStream: stream, sourceSeq: seq, updatedAt: now as never
        })
        .onConflictDoUpdate({
          target: [homeParticipants.conversationId, homeParticipants.participantId],
          set: {
            kind: ex(homeParticipants.kind), visibleFromSeq: ex(homeParticipants.visibleFromSeq), joinedAt: joined === null ? sql.raw(`"home_participants"."joined_at"`) : ex(homeParticipants.joinedAt),
            leftAt: ex(homeParticipants.leftAt), sourceStream: ex(homeParticipants.sourceStream), sourceSeq: ex(homeParticipants.sourceSeq), updatedAt: now
          },
          setWhere: newer(homeParticipants)
        })
    )
  },
  "home.invite.upsert": (p, stream, seq) =>
    render(
      db
        .insert(homeInvites)
        .values({
          id: String(p.id), conversationId: String(p.conversation_id), invitedBy: String(p.invited_by), addressId: String(p.address_id), channel: String(p.channel), status: String(p.status),
          deliveryState: String(p.delivery_state), copyVariant: String(p.copy_variant), createdAt: String(p.created_at), expiresAt: String(p.expires_at), acceptedBy: text(p.accepted_by),
          acceptedAt: text(p.accepted_at), sourceStream: stream, sourceSeq: seq, updatedAt: now as never
        })
        .onConflictDoUpdate({
          target: homeInvites.id,
          set: {
            status: ex(homeInvites.status), deliveryState: ex(homeInvites.deliveryState), expiresAt: ex(homeInvites.expiresAt), acceptedBy: ex(homeInvites.acceptedBy),
            acceptedAt: ex(homeInvites.acceptedAt), sourceStream: ex(homeInvites.sourceStream), sourceSeq: ex(homeInvites.sourceSeq), updatedAt: now
          },
          setWhere: newer(homeInvites)
        })
    )
}
