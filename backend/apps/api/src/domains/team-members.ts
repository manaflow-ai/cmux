import type { RowReader, RowWrite } from "@cmux/ownership"
import type { Host, TeamMember } from "@cmux/protocol"

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
/** Rows subscribers never get in event effects: clients page members and hosts with reads. */
export const TEAM_PRIVATE_TABLES: ReadonlyArray<string> = [TABLE_MEMBER, TABLE_HOST, TABLE_HOST_BY_INSTALL]

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

/** Targets one reach check resolves at most (the group size cap, section 4.1); a longer list gets no answer. */
export const HOME_REACH_MAX_TARGETS = 64

/**
 * Home reach (home-messaging.md section 16.7, home-reach.ts): which of `targets` share this team
 * with `adder`, with their directory names. Only owner, admin and member roles may add people.
 */
export const homeCoMembersOf = (s: LegacyTeamMaps, rows: RowReader | undefined, adder: string, targets: ReadonlyArray<string>): Array<{ user: string; display_name: string }> => {
  if (!Array.isArray(targets) || targets.length > HOME_REACH_MAX_TARGETS) return []
  if (!["owner", "admin", "member"].includes(roleOf(s, rows, adder) ?? "")) return []
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

export const hostUpsert = (h: HostRecord): Array<RowWrite> => [
  { table: TABLE_HOST, op: "upsert", key: h.id, n: null, row: h },
  { table: TABLE_HOST_BY_INSTALL, op: "upsert", key: h.enrolled_by, n: null, row: { host: h.id } }
]

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

/** One page of hosts by host id (keyset). */
export const listHosts = (s: LegacyTeamMaps, rows: RowsWithScan | undefined, after: string | undefined, limit: number): { items: Array<HostRecord>; next: string | null } =>
  page(Object.values(s.hosts ?? {}).map((h) => [h.id, h] as const), rows?.scanFrom?.<HostRecord>(TABLE_HOST, after, limit + 1) ?? [], after, limit)

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
 * pending integration approvals. Each carries the removal's tx (no coalescing with a later
 * re-join) and time `at`: a late delivery touches only what existed at removal.
 */
export const memberLeftItems = (team: { readonly id: string; readonly kind: string }, user: string, tx: string, at: number) => [
  teamIndexItem(team, user, null, tx),
  { kind: "user.team_left", entity: `team-left:${team.id}:${user}:${tx}`, payload: { team: team.id, at }, target: { class: "UserDO", name: user } },
  { kind: "connections.member_left", entity: `member-left:${team.id}:${user}:${tx}`, payload: { team: team.id, user, at }, target: { class: "ConnectionDO", name: team.id } }
]
