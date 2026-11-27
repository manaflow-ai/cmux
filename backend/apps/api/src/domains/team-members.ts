import type { RowReader, RowWrite } from "@cmux/ownership"
import type { Host, TeamMember } from "@cmux/protocol"
import { roleHas, type TeamGrant } from "./team-roles.ts"

/**
 * TeamDO members and hosts live in rows ((f), DO audit F-1): the head stays small for 10k+ member
 * teams. Old heads still hold `members`/`hosts` maps until `team.rows_migrate` moves them; every
 * lookup reads the row first and the legacy map second, so a head before the migration (and a
 * pure test state) answers the same.
 */
export const TABLE_MEMBER = "member"
export const TABLE_HOST = "host"
/** install id -> host id (a server or host enrolled by that install). */
export const TABLE_HOST_BY_INSTALL = "host_by_install"
/**
 * host id -> the dev build space it was enrolled from (apps/api build-space.ts). TeamDO is one object for every build
 * of a person, but its directory of registered Macs and hosts is per build: a host with no row here is nightly and
 * stable's (space ""), and a build lists and acts on only the hosts of its own space.
 */
export const TABLE_HOST_SPACE = "host_space"
/** Rows subscribers never get in event effects: clients page members, hosts and audit records (team-audit-rows.ts) with reads. */
export const TEAM_PRIVATE_TABLES: ReadonlyArray<string> = [TABLE_MEMBER, TABLE_HOST, TABLE_HOST_BY_INSTALL, TABLE_HOST_SPACE, "audit", "group", "group_member", "group_item", "group_ws", "member_authority", "cloud_session", "cloud_recent", "cloud_follow", "cloud_follower", "cloud_viewer"]

export type Member = typeof TeamMember.Type
export type HostRecord = typeof Host.Type

/** The legacy maps an old head may still carry. */
export interface LegacyTeamMaps {
  readonly members?: Readonly<Record<string, Member>>
  readonly hosts?: Readonly<Record<string, HostRecord>>
}

export const memberOf = (s: LegacyTeamMaps, rows: RowReader | undefined, user: string | undefined): Member | undefined =>
  user === undefined ? undefined : (rows?.get<Member>(TABLE_MEMBER, user)?.row ?? s.members?.[user])

export const roleOf = (s: LegacyTeamMaps, rows: RowReader | undefined, user: string | undefined) => memberOf(s, rows, user)?.role

/** Whether `user` holds `grant` in this team now: the member row's role bundle (team-roles.ts), read on every op. */
export const can = (s: LegacyTeamMaps, rows: RowReader | undefined, user: string | undefined, grant: TeamGrant): boolean => roleHas(roleOf(s, rows, user), grant)

/** Targets one reach check resolves at most (the group size cap, section 4.1); a longer list gets no answer. */
export const HOME_REACH_MAX_TARGETS = 64

/**
 * Home reach (home-messaging.md section 16.7, home-reach.ts): which of `targets` share this team
 * with `adder`, with their directory names. Only roles with the team.resources grant may add people.
 */
export const homeCoMembersOf = (s: LegacyTeamMaps, rows: RowReader | undefined, adder: string, targets: ReadonlyArray<string>): Array<{ user: string; display_name: string }> => {
  if (!Array.isArray(targets) || targets.length > HOME_REACH_MAX_TARGETS) return []
  if (!can(s, rows, adder, "team.resources")) return []
  return targets.flatMap((user) => {
    const member = user === adder ? undefined : memberOf(s, rows, user)
    return member ? [{ user, display_name: member.display_name }] : []
  })
}

export const hostOf = (s: LegacyTeamMaps, rows: RowReader | undefined, id: string): HostRecord | undefined => rows?.get<HostRecord>(TABLE_HOST, id)?.row ?? s.hosts?.[id]

export const hostByInstall = (s: LegacyTeamMaps, rows: RowReader | undefined, install: string): HostRecord | undefined => {
  const id = rows?.get<{ host: string }>(TABLE_HOST_BY_INSTALL, install)?.row.host
  return id !== undefined ? hostOf(s, rows, id) : Object.values(s.hosts ?? {}).find((h) => h.enrolled_by === install)
}

export const memberUpsert = (m: Member): RowWrite => ({ table: TABLE_MEMBER, op: "upsert", key: m.user, n: null, row: m })

/** The build space a host belongs to ("" for nightly and stable). */
export const hostSpaceOf = (rows: RowReader | undefined, id: string): string => rows?.get<{ space: string }>(TABLE_HOST_SPACE, id)?.row.space ?? ""

/** The space a principal acts in (the Worker sets build_space only for a dev space). */
export const principalSpace = (p: { readonly build_space?: string }): string => p.build_space ?? ""

/** Whether `p` may see host `id`: only hosts of the principal's own build space. */
export const hostInSpace = (rows: RowReader | undefined, id: string, p: { readonly build_space?: string }): boolean => hostSpaceOf(rows, id) === principalSpace(p)

/** A host's projection payload: its team and, for a dev build's host, its space (projection rows are keyed by it). */
export const hostPayload = (h: HostRecord, team: string | undefined, space: string): Record<string, unknown> => ({ ...h, team, ...(space ? { space } : {}) })

/** `space` is set only when a host is first enrolled: a host never moves between spaces, so later upserts leave it. */
export const hostUpsert = (h: HostRecord, space?: string): Array<RowWrite> => [
  { table: TABLE_HOST, op: "upsert", key: h.id, n: null, row: h },
  { table: TABLE_HOST_BY_INSTALL, op: "upsert", key: h.enrolled_by, n: null, row: { host: h.id } },
  ...(space ? [{ table: TABLE_HOST_SPACE, op: "upsert" as const, key: h.id, n: null, row: { space } }] : [])
]

/**
 * The host's space row stays: work queued for a removed host (its replica drop in HostDO) still has to reach the
 * removed host's own build space, and a host id is never reused.
 */
export const hostDelete = (h: HostRecord): Array<RowWrite> => [
  { table: TABLE_HOST, op: "delete", key: h.id },
  { table: TABLE_HOST_BY_INSTALL, op: "delete", key: h.enrolled_by }
]

/** The DO's row store also pages unordered tables by key (SqlRows.scanFrom). */
export interface RowsWithScan extends RowReader {
  scanFrom?<T>(table: string, afterKey: string | undefined, limit: number): Array<{ key: string; row: T }>
}

/** One page of members by user id (keyset), rows first, then any legacy map entries. */
export const listMembers = (s: LegacyTeamMaps, rows: RowsWithScan | undefined, after: string | undefined, limit: number): { items: Array<Member>; next: string | null } =>
  page(Object.values(s.members ?? {}).map((m) => [m.user, m] as const), rows?.scanFrom?.<Member>(TABLE_MEMBER, after, limit + 1) ?? [], after, limit)

/** The owner with the smallest user id (deterministic), or undefined; scans at most `maxPages` pages. */
export const firstOwner = (s: LegacyTeamMaps, rows: RowsWithScan | undefined, maxPages = 50): string | undefined => {
  let after: string | undefined
  for (let i = 0; i < maxPages; i++) {
    const { items, next } = listMembers(s, rows, after, 200)
    const owner = items.find((m) => m.role === "owner")
    if (owner) return owner.user
    if (!next) return undefined
    after = next
  }
  return undefined
}

/** One page of hosts by host id (keyset), every space. */
export const listAllHosts = (s: LegacyTeamMaps, rows: RowsWithScan | undefined, after: string | undefined, limit: number): { items: Array<HostRecord>; next: string | null } =>
  page(Object.values(s.hosts ?? {}).map((h) => [h.id, h] as const), rows?.scanFrom?.<HostRecord>(TABLE_HOST, after, limit + 1) ?? [], after, limit)

/** Pages one scan step reads while it filters to a build space: a page is never empty while hosts of the space remain within it. */
const HOST_SPACE_STEPS = 20

/** One page of the hosts of `p`'s build space by host id (keyset). */
export const listHosts = (s: LegacyTeamMaps, rows: RowsWithScan | undefined, after: string | undefined, limit: number, p: { readonly build_space?: string }): { items: Array<HostRecord>; next: string | null } => {
  const out: Array<HostRecord> = []
  let cursor = after
  let next: string | null = null
  for (let steps = 0; steps < HOST_SPACE_STEPS && out.length < limit; steps++) {
    const pageOf = listAllHosts(s, rows, cursor, limit)
    for (const h of pageOf.items) if (out.length < limit && hostInSpace(rows, h.id, p)) out.push(h)
    next = pageOf.next
    if (next === null) break
    cursor = next
  }
  return { items: out, next: out.length < limit && next === null ? null : (out.at(-1)?.id ?? next) }
}

const page = <T>(legacy: ReadonlyArray<readonly [string, T]>, fromRows: ReadonlyArray<{ key: string; row: T }>, after: string | undefined, limit: number) => {
  const merged = new Map<string, T>()
  for (const [k, v] of legacy) if (after === undefined || k > after) merged.set(k, v)
  for (const r of fromRows) merged.set(r.key, r.row)
  const keys = [...merged.keys()].sort().slice(0, limit + 1)
  const items = keys.slice(0, limit).map((k) => merged.get(k)!)
  return { items, next: keys.length > limit ? keys[limit - 1]! : null }
}

/** The E4 item that keeps the member's UserDO team index in step (newest per team wins). */
export const teamIndexItem = (team: { readonly id: string; readonly kind: string }, user: string, role: string | null, tx: string) => ({
  kind: "user.team_index",
  entity: `team-index:${team.id}:${user}:${tx}`,
  payload: { team: team.id, role, kind: team.kind },
  target: { class: "UserDO", name: user, coalesce: `team-index:${team.id}` }
})

/**
 * What a member's removal tells the other owners (cx-44j.47): the user's team index entry goes,
 * UserDO revokes the installs bound to the team, and the team's ConnectionDO ends the user's
 * pending integration approvals, and the team's CloudDO closes the user's sockets there (the
 * team's socket owners other than TeamDO, which closes its own in the same turn). Each carries the removal's tx (no coalescing with a later
 * re-join) and time `at`: a late delivery touches only what existed at removal.
 */
export const memberLeftItems = (team: { readonly id: string; readonly kind: string }, user: string, tx: string, at: number) => [
  teamIndexItem(team, user, null, tx),
  { kind: "user.team_left", entity: `team-left:${team.id}:${user}:${tx}`, payload: { team: team.id, at }, target: { class: "UserDO", name: user } },
  { kind: "connections.member_left", entity: `member-left:${team.id}:${user}:${tx}`, payload: { team: team.id, user, at }, target: { class: "ConnectionDO", name: team.id } },
  { kind: TEAM_MEMBER_LEFT_SOCKETS, entity: `sockets-left:${team.id}:${user}:${tx}`, payload: { team: team.id, user, at }, target: { class: "CloudDO", name: team.id } }
]

/** The item a team-keyed socket owner (CloudDO) gets when a member leaves: it closes that user's sockets. */
export const TEAM_MEMBER_LEFT_SOCKETS = "team.member_left.sockets"
