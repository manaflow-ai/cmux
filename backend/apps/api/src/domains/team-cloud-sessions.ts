import type { ReduceContext, RowReader, RowWrite } from "@cmux/ownership"
import {
  CLOUD_SESSION_LINK_PREFIX,
  CLOUD_WORKSPACE_LINK_PREFIX,
  CloudSessionArchive,
  CloudSessionFollow,
  CloudSessionPublish,
  CloudSessionReassign,
  CloudSessionRemove,
  CloudSessionView,
  CloudSessionViewing
} from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import { memberOf, type LegacyTeamMaps } from "./team-members.ts"
import { roleHas } from "./team-roles.ts"
import type { ReadResult } from "../owner-do.ts"

/**
 * Team-visible Cloud sessions in TeamDO (protocol team-cloud-session-ops.ts). Rows only, so a team
 * with thousands of Cloud chats keeps a small head:
 *
 * - `cloud_session` (key `<vm>/<session>`): the record.
 * - `cloud_recent` (key `<inverted last activity, 16 digits>|<vm>/<session>`): the list order, newest
 *   first; the row moves when its last activity moves.
 * - `cloud_follow` (key `<user>|<vm>/<session>`): what a person follows (the Following section).
 * - `cloud_follower` (key `<vm>/<session>|<user>`): who follows a session (its avatar stack).
 * - `cloud_viewer` (key `<vm>/<session>|<user>`, `{at}`): who had it open, shown for VIEWER_TTL_MS.
 *
 * Every row is private: clients read with team.cloud.session.list / .get. Team membership and the
 * team.resources grant are checked by TeamDO's authorize (ops) and teamRead (reads) on every call,
 * so a member removed from the team loses the list, links, follows and presence at once.
 */
export const TABLE_CLOUD_SESSION = "cloud_session"
export const TABLE_CLOUD_RECENT = "cloud_recent"
export const TABLE_CLOUD_FOLLOW = "cloud_follow"
export const TABLE_CLOUD_FOLLOWER = "cloud_follower"
export const TABLE_CLOUD_VIEWER = "cloud_viewer"
export const CLOUD_SESSION_TABLES: ReadonlyArray<string> = [TABLE_CLOUD_SESSION, TABLE_CLOUD_RECENT, TABLE_CLOUD_FOLLOW, TABLE_CLOUD_FOLLOWER, TABLE_CLOUD_VIEWER]
export const CLOUD_SESSION_OPS: ReadonlySet<string> = new Set([
  "team.cloud.session.publish",
  "team.cloud.session.remove",
  "team.cloud.session.follow",
  "team.cloud.session.reassign",
  "team.cloud.session.archive",
  "team.cloud.session.viewing"
])
export const CLOUD_SESSION_READS: ReadonlySet<string> = new Set(["team.cloud.session.list", "team.cloud.session.get"])

/** A viewer shows for 90 s after its last `viewing` (the app repeats it every 60 s while it shows). */
export const VIEWER_TTL_MS = 90_000
/** Followers and viewers a view lists (the counts are exact up to FOLLOWER_SCAN). */
const AVATARS = 20
const FOLLOWER_SCAN = 500
const PAGE = 200
/** Upper bound of the recent index's inverted timestamp (year 2255). */
const INVERT_BASE = 9_000_000_000_000_000

type View = typeof CloudSessionView.Type
type Kind = View["kind"]
export interface CloudSessionRow {
  readonly vm: string
  readonly session: string
  readonly kind: Kind
  readonly workspace?: string
  readonly title: string
  readonly harness?: string
  readonly owner: string
  readonly assignee: string
  readonly machine_state: View["machine_state"]
  readonly activity: View["activity"]
  readonly last_activity_at: number
  readonly created_at: number
  readonly archived: boolean
}

type KeyRows = RowReader & { keyRange?: <T>(t: string, q: { after?: string; before?: string; limit: number }) => Array<{ key: string; row: T }> }
type Reduced<S> = { ok: true; state: S; value: unknown; changed?: boolean; writes?: ReadonlyArray<RowWrite> } | ReturnType<typeof reject>

export const sessionKey = (vm: string, session: string) => `${vm}/${session}`
const recentKey = (r: Pick<CloudSessionRow, "vm" | "session" | "last_activity_at">) =>
  `${String(INVERT_BASE - Math.max(0, Math.min(r.last_activity_at, INVERT_BASE))).padStart(16, "0")}|${sessionKey(r.vm, r.session)}`
const put = (table: string, key: string, row: unknown): RowWrite => ({ table, op: "upsert", key, n: null, row })
const del = (table: string, key: string): RowWrite => ({ table, op: "delete", key })
const range = <T>(rows: KeyRows | undefined, table: string, prefix: string, limit: number, after?: string) =>
  rows?.keyRange?.<T>(table, { after: after ?? prefix, before: `${prefix}\u007f`, limit }) ?? []

export const cloudSessionOf = (rows: RowReader | undefined, vm: string, session: string): CloudSessionRow | undefined =>
  rows?.get<CloudSessionRow>(TABLE_CLOUD_SESSION, sessionKey(vm, session))?.row

export const cloudSessionLink = (team: string, r: Pick<CloudSessionRow, "kind" | "vm" | "session">) =>
  `${r.kind === "chat" ? CLOUD_SESSION_LINK_PREFIX : CLOUD_WORKSPACE_LINK_PREFIX}${team}/${r.vm}/${r.session}`

/** Whether `user` (a member with team.resources) may reassign or archive `r`. */
const mayManage = (state: LegacyTeamMaps, rows: RowReader | undefined, r: CloudSessionRow, user: string) =>
  user === r.assignee || user === r.owner || roleHas(memberOf(state, rows, user)?.role, "team.manage")

/** A member who can see the team's resources (not a guest or billing member, not removed). */
const activeMember = (state: LegacyTeamMaps, rows: RowReader | undefined, user: string) => roleHas(memberOf(state, rows, user)?.role, "team.resources")

export const sessionView = (state: LegacyTeamMaps & { team: { id: string } | null }, rows: KeyRows | undefined, r: CloudSessionRow, caller: string, now: number): View => {
  const base = sessionKey(r.vm, r.session)
  const followers = range<{ user: string }>(rows, TABLE_CLOUD_FOLLOWER, `${base}|`, FOLLOWER_SCAN)
    .map((x) => x.row.user)
    .filter((u) => activeMember(state, rows, u))
  const following = followers.includes(caller)
  const viewers = range<{ user: string; at: number }>(rows, TABLE_CLOUD_VIEWER, `${base}|`, FOLLOWER_SCAN)
    .filter((x) => now - x.row.at < VIEWER_TTL_MS && activeMember(state, rows, x.row.user))
    .map((x) => x.row.user)
  const team = state.team?.id ?? ""
  return {
    key: `cloud:${team}/${base}`,
    team,
    vm: r.vm,
    session: r.session,
    kind: r.kind,
    ...(r.workspace !== undefined ? { workspace: r.workspace } : {}),
    title: r.title,
    ...(r.harness !== undefined ? { harness: r.harness } : {}),
    owner: r.owner,
    owner_name: memberOf(state, rows, r.owner)?.display_name ?? null,
    assignee: r.assignee,
    assignee_name: activeMember(state, rows, r.assignee) ? (memberOf(state, rows, r.assignee)?.display_name ?? null) : null,
    machine_state: r.machine_state,
    activity: r.activity,
    last_activity_at: r.last_activity_at,
    created_at: r.created_at,
    archived: r.archived,
    followers: (following ? [caller, ...followers.filter((u) => u !== caller)] : followers).slice(0, AVATARS),
    follower_count: followers.length,
    following,
    assigned_to_you: r.assignee === caller,
    viewers: viewers.slice(0, AVATARS),
    can_reassign: mayManage(state, rows, r, caller),
    can_archive: mayManage(state, rows, r, caller),
    link: cloudSessionLink(team, r)
  }
}

const notFound = () => reject("cloud_session.not_found", "no such Cloud session in this team; it was closed or removed")

/** The writes that drop every follow of a session (bounded: FOLLOWER_SCAN followers). */
const dropFollows = (rows: KeyRows | undefined, base: string): Array<RowWrite> =>
  range<{ user: string }>(rows, TABLE_CLOUD_FOLLOWER, `${base}|`, FOLLOWER_SCAN).flatMap((x) => [del(TABLE_CLOUD_FOLLOWER, x.key), del(TABLE_CLOUD_FOLLOW, `${x.row.user}|${base}`)])
const follow = (base: string, user: string): Array<RowWrite> => [put(TABLE_CLOUD_FOLLOWER, `${base}|${user}`, { user }), put(TABLE_CLOUD_FOLLOW, `${user}|${base}`, { key: base })]
const unfollow = (base: string, user: string): Array<RowWrite> => [del(TABLE_CLOUD_FOLLOWER, `${base}|${user}`), del(TABLE_CLOUD_FOLLOW, `${user}|${base}`)]

/** The view after `writes` land (the reducer's answer reads its own writes through an overlay). */
const overlay = (rows: KeyRows | undefined, writes: ReadonlyArray<RowWrite>): KeyRows => {
  const changed = new Map<string, RowWrite>()
  for (const w of writes) changed.set(`${w.table}\u0000${w.key}`, w)
  const get = <T>(table: string, key: string) => {
    const w = changed.get(`${table}\u0000${key}`)
    if (w) return w.op === "delete" ? undefined : { key, n: null, row: w.row as T }
    return rows?.get<T>(table, key)
  }
  return {
    get,
    range: (t, q) => rows?.range(t, q) ?? [],
    keyRange: <T>(table: string, q: { after?: string; before?: string; limit: number }) => {
      const base = (rows?.keyRange?.<T>(table, { ...q, limit: q.limit + writes.length }) ?? []).filter((r) => !changed.has(`${table}\u0000${r.key}`))
      const added = [...changed.values()]
        .filter((w): w is Extract<RowWrite, { op: "upsert" }> => w.op === "upsert" && w.table === table && (q.after === undefined || w.key > q.after) && (q.before === undefined || w.key < q.before))
        .map((w) => ({ key: w.key, row: w.row as T }))
      return [...base, ...added].sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0)).slice(0, q.limit)
    }
  }
}

export const reduceCloudSession = <S extends LegacyTeamMaps & { team: { id: string } | null }>(state: S, op: string, params: unknown, ctx: ReduceContext): Reduced<S> => {
  if (!state.team) return reject("validation.invalid", "team not initialized")
  const user = ctx.principal.user
  if (!user) return reject("auth.forbidden", "Cloud sessions need a person (a session or that person's install)")
  const rows = ctx.rows as KeyRows | undefined
  const answer = (r: CloudSessionRow, writes: Array<RowWrite>, changed = true): Reduced<S> => ({
    ok: true,
    state,
    value: sessionView(state, overlay(rows, writes), r, user, ctx.now),
    ...(changed ? { writes } : { changed: false })
  })
  switch (op) {
    case "team.cloud.session.publish": {
      const d = decodeParams<typeof CloudSessionPublish.params.Type>(CloudSessionPublish, params)
      if (!d.ok) return d
      const p = d.value
      const prior = cloudSessionOf(rows, p.vm, p.session)
      if (prior && user !== prior.owner && user !== prior.assignee) return reject("cloud_session.not_yours", "only the session's owner or assignee publishes it")
      if (prior && prior.kind !== p.kind) return reject("validation.invalid", "a session's kind never changes")
      const next: CloudSessionRow = {
        vm: p.vm,
        session: p.session,
        kind: p.kind,
        ...(p.workspace !== undefined ? { workspace: p.workspace } : prior?.workspace !== undefined ? { workspace: prior.workspace } : {}),
        title: p.title,
        ...(p.harness !== undefined ? { harness: p.harness } : prior?.harness !== undefined ? { harness: prior.harness } : {}),
        owner: prior?.owner ?? user,
        assignee: prior?.assignee ?? user,
        machine_state: p.machine_state,
        activity: p.activity,
        // Never back in time: two publishers (the Mac and the VM) may race.
        last_activity_at: Math.max(prior?.last_activity_at ?? 0, p.last_activity_at),
        created_at: prior?.created_at ?? ctx.now,
        archived: prior?.archived ?? false
      }
      if (prior && JSON.stringify(prior) === JSON.stringify(next)) return answer(prior, [], false)
      const base = sessionKey(p.vm, p.session)
      const writes = [put(TABLE_CLOUD_SESSION, base, next), ...(prior && recentKey(prior) !== recentKey(next) ? [del(TABLE_CLOUD_RECENT, recentKey(prior))] : []), put(TABLE_CLOUD_RECENT, recentKey(next), { key: base })]
      return answer(next, writes)
    }
    case "team.cloud.session.remove": {
      const d = decodeParams<typeof CloudSessionRemove.params.Type>(CloudSessionRemove, params)
      if (!d.ok) return d
      const prior = cloudSessionOf(rows, d.value.vm, d.value.session)
      if (!prior) return { ok: true, state, value: { removed: false }, changed: false }
      if (!mayManage(state, rows, prior, user)) return reject("cloud_session.not_yours", "only the session's owner or assignee, or a team owner or admin, removes it")
      const base = sessionKey(prior.vm, prior.session)
      const viewers = range<unknown>(rows, TABLE_CLOUD_VIEWER, `${base}|`, FOLLOWER_SCAN).map((x) => del(TABLE_CLOUD_VIEWER, x.key))
      return { ok: true, state, value: { removed: true }, writes: [del(TABLE_CLOUD_SESSION, base), del(TABLE_CLOUD_RECENT, recentKey(prior)), ...dropFollows(rows, base), ...viewers] }
    }
    case "team.cloud.session.follow": {
      const d = decodeParams<typeof CloudSessionFollow.params.Type>(CloudSessionFollow, params)
      if (!d.ok) return d
      const r = cloudSessionOf(rows, d.value.vm, d.value.session)
      if (!r) return notFound()
      const base = sessionKey(r.vm, r.session)
      const now = rows?.get(TABLE_CLOUD_FOLLOWER, `${base}|${user}`) !== undefined
      if (d.value.follow && r.assignee === user) return reject("cloud_session.assigned_to_you", "it is assigned to you, so it is already under Assigned to me")
      if (now === d.value.follow) return answer(r, [], false)
      return answer(r, d.value.follow ? follow(base, user) : unfollow(base, user))
    }
    case "team.cloud.session.reassign": {
      const d = decodeParams<typeof CloudSessionReassign.params.Type>(CloudSessionReassign, params)
      if (!d.ok) return d
      const r = cloudSessionOf(rows, d.value.vm, d.value.session)
      if (!r) return notFound()
      if (!mayManage(state, rows, r, user)) return reject("auth.forbidden", "only the session's assignee or owner, or a team owner or admin, reassigns it")
      const to = d.value.to
      if (!activeMember(state, rows, to)) return reject("cloud_session.assignee_not_member", "the new assignee is not a member of this team who can use its Cloud work (guests cannot)")
      if (to === r.assignee) return answer(r, [], false)
      const base = sessionKey(r.vm, r.session)
      const next: CloudSessionRow = { ...r, assignee: to }
      // The new assignee's follow goes (it is theirs now); the previous one keeps it in their workflow as a
      // follower (Conductor: "followers keep following"); everyone else's follow is untouched.
      const prev = r.assignee
      const writes = [
        put(TABLE_CLOUD_SESSION, base, next),
        ...unfollow(base, to),
        ...(activeMember(state, rows, prev) ? follow(base, prev) : [])
      ]
      return answer(next, writes)
    }
    case "team.cloud.session.archive": {
      const d = decodeParams<typeof CloudSessionArchive.params.Type>(CloudSessionArchive, params)
      if (!d.ok) return d
      const r = cloudSessionOf(rows, d.value.vm, d.value.session)
      if (!r) return notFound()
      if (!mayManage(state, rows, r, user)) return reject("auth.forbidden", "only the session's assignee or owner, or a team owner or admin, archives it")
      if (r.archived === d.value.archived) return answer(r, [], false)
      const next = { ...r, archived: d.value.archived }
      return answer(next, [put(TABLE_CLOUD_SESSION, sessionKey(r.vm, r.session), next)])
    }
    case "team.cloud.session.viewing": {
      const d = decodeParams<typeof CloudSessionViewing.params.Type>(CloudSessionViewing, params)
      if (!d.ok) return d
      const r = cloudSessionOf(rows, d.value.vm, d.value.session)
      if (!r) return notFound()
      const key = `${sessionKey(r.vm, r.session)}|${user}`
      const writes = d.value.viewing ? [put(TABLE_CLOUD_VIEWER, key, { user, at: ctx.now })] : [del(TABLE_CLOUD_VIEWER, key)]
      const view = sessionView(state, overlay(rows, writes), r, user, ctx.now)
      return { ok: true, state, value: { viewing: d.value.viewing, viewers: view.viewers }, writes }
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/** team.cloud.session.list / .get (teamRead checked membership and team.resources already). */
export const cloudSessionRead = (state: LegacyTeamMaps & { team: { id: string } | null }, op: string, params: unknown, user: string, rows: KeyRows | undefined, now = Date.now()): ReadResult => {
  const q = (params ?? {}) as { vm?: unknown; session?: unknown; scope?: unknown; by?: unknown; archived?: unknown; cursor?: unknown; limit?: unknown }
  if (op === "team.cloud.session.get") {
    const r = typeof q.vm === "string" && typeof q.session === "string" ? cloudSessionOf(rows, q.vm, q.session) : undefined
    // As a group read answers (team-group-reads.ts): selector.not_found, the read path's own code.
    if (!r) return { ok: false, code: "selector.not_found", message: "no such Cloud session in this team; it was closed or removed" }
    return { ok: true, value: { session: sessionView(state, rows, r, user, now) }, revision: "" }
  }
  const scope = q.scope === undefined ? "team" : q.scope
  if (scope !== "mine" && scope !== "team" && scope !== "following") return { ok: false, code: "validation.invalid", message: "scope is mine, team or following" }
  if (q.by !== undefined && (typeof q.by !== "string" || !q.by.startsWith("user_"))) return { ok: false, code: "validation.invalid", message: "by is a user id" }
  const limit = typeof q.limit === "number" && Number.isInteger(q.limit) ? Math.min(Math.max(q.limit, 1), PAGE) : 50
  const cursor = typeof q.cursor === "string" && q.cursor.length <= 256 ? q.cursor : undefined
  const archived = q.archived === true
  const by = scope === "mine" ? user : (q.by as string | undefined)
  const keep = (r: CloudSessionRow) => r.archived === archived && (by === undefined || r.assignee === by)
  const out: Array<View> = []
  let next: string | null = null
  if (scope === "following") {
    // The person's follows in key order (a small set), then newest first.
    const prefix = `${user}|`
    const all = range<{ key: string }>(rows, TABLE_CLOUD_FOLLOW, prefix, 1000)
      .map((x) => rows?.get<CloudSessionRow>(TABLE_CLOUD_SESSION, x.row.key)?.row)
      .filter((r): r is CloudSessionRow => r !== undefined && keep(r))
      .sort((a, b) => b.last_activity_at - a.last_activity_at || (sessionKey(a.vm, a.session) < sessionKey(b.vm, b.session) ? -1 : 1))
    const start = cursor ? Math.max(0, all.findIndex((r) => recentKey(r) === cursor) + 1) : 0
    const page = all.slice(start, start + limit)
    for (const r of page) out.push(sessionView(state, rows, r, user, now))
    next = start + limit < all.length && page.length > 0 ? recentKey(page.at(-1)!) : null
  } else {
    // The recent index, newest first; filtered rows are skipped in bounded steps so a page is never
    // empty while matches remain.
    let after = cursor
    for (let steps = 0; steps < 20 && out.length < limit; steps++) {
      const page = rows?.keyRange?.<{ key: string }>(TABLE_CLOUD_RECENT, { ...(after !== undefined ? { after } : {}), limit: limit + 1 }) ?? []
      let full = false
      for (const x of page.slice(0, limit)) {
        after = x.key
        const r = rows?.get<CloudSessionRow>(TABLE_CLOUD_SESSION, x.row.key)?.row
        if (r && keep(r)) out.push(sessionView(state, rows, r, user, now))
        if (out.length >= limit) {
          full = true
          break
        }
      }
      next = full || page.length > limit ? (after ?? null) : null
      if (next === null) break
    }
  }
  return { ok: true, value: { team: state.team?.id ?? "", sessions: out, next_cursor: next }, revision: "" }
}
