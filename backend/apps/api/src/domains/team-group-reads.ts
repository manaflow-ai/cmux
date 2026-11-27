import type { ReadResult } from "../owner-do.ts"
import type { RowsWithScan } from "./team-members.ts"
import { groupItems, groupLinks, groupOf, groupView, roleIn, TABLE_GROUP_MEMBER, type GroupRow } from "./team-groups.ts"
import type { TeamState } from "./team.ts"

/** Rows that also read a key range (SqlRows.keyRange); pure test readers may lack it and answer empty. */
type KeyRows = RowsWithScan & { keyRange?: <T>(t: string, q: { after?: string; before?: string; limit: number }) => Array<{ key: string; row: T }> }

const PAGE = 200

/**
 * group.get and group.list (cloud-groups-DESIGN.md slice 1). TeamDO already checked team membership
 * and the team.resources grant (team-reads.ts); here a group answers only to its own members. A group
 * that is missing and one the caller is not a member of give the same `selector.not_found`.
 */
export const groupRead = (state: TeamState, op: string, params: unknown, user: string, rows: KeyRows | undefined): ReadResult => {
  const q = (params ?? {}) as { group?: unknown; cursor?: unknown; limit?: unknown; include_archived?: unknown }
  if (op === "group.get") {
    const g = typeof q.group === "string" ? groupOf(rows, q.group) : undefined
    if (!g || !roleIn(g, user)) return { ok: false, code: "selector.not_found", message: "no such group" }
    return { ok: true, value: { group: groupView(g, user), items: groupItems(rows, g.id), ...groupLinks(g.id) }, revision: "" }
  }
  const limit = typeof q.limit === "number" && Number.isInteger(q.limit) ? Math.min(Math.max(q.limit, 1), PAGE) : PAGE
  const cursor = typeof q.cursor === "string" && q.cursor.startsWith("grp_") && q.cursor.length <= 128 ? q.cursor : undefined
  const withArchived = q.include_archived === true
  const prefix = `${user}:`
  const groups: Array<ReturnType<typeof groupView>> = []
  let after = cursor ? `${prefix}${cursor}` : prefix
  let next: string | null = null
  // Archived groups are skipped in bounded steps, so a page is never empty while matches remain.
  for (let steps = 0; steps < 20 && groups.length < limit; steps++) {
    const page = rows?.keyRange?.<{ group: string }>(TABLE_GROUP_MEMBER, { after, before: `${user};`, limit: limit + 1 }) ?? []
    let full = false
    for (const r of page.slice(0, limit)) {
      after = r.key
      const g = rows?.get<GroupRow>("group", r.row.group)?.row
      if (g && roleIn(g, user) && (withArchived || !g.archived)) groups.push(groupView(g, user))
      if (groups.length >= limit) {
        full = true
        break
      }
    }
    next = full || page.length > limit ? after.slice(prefix.length) : null
    if (next === null) break
  }
  return { ok: true, value: { team: state.team?.id ?? "", groups, next_cursor: groups.length < limit && next === null ? null : next }, revision: "" }
}
