import type { ReduceContext, RowReader, RowWrite } from "@cmux/ownership"
import { CloudGroup, CloudGroupItem, GROUP_LINK_PREFIX, GROUP_WEB_LINK_PREFIX, GroupAddWorkspace, GroupArchive, GroupCreate, GroupId, GroupRename } from "@cmux/protocol"
import { Schema } from "effect"
import { decodeParams, reject } from "./common.ts"
import type { TeamState } from "./team.ts"

/**
 * Cloud groups in TeamDO (plans/cmux-next/cloud-groups-DESIGN.md, slice 1). Rows only, the head is
 * untouched, so a team with thousands of groups keeps a small head:
 *
 * - `group` (key = group id): the record, with its members (slice 1: the creator as owner).
 * - `group_member` (key = `<user>:<group>`): the index group.list pages for one person.
 * - `group_item` (key = `<group>:<workspace>`): a workspace in the group, with its placement.
 * - `group_ws` (key = workspace id): which group holds a workspace (one cloud group per workspace).
 *
 * TeamDO mints the id (ctx.newId, deterministic per commit, so a replay gives the same id); a client
 * never names it. Every row is private: clients read groups with group.get / group.list.
 */
export const TABLE_GROUP = "group"
export const TABLE_GROUP_MEMBER = "group_member"
export const TABLE_GROUP_ITEM = "group_item"
export const TABLE_GROUP_WS = "group_ws"
export const GROUP_TABLES: ReadonlyArray<string> = [TABLE_GROUP, TABLE_GROUP_MEMBER, TABLE_GROUP_ITEM, TABLE_GROUP_WS]
export const GROUP_OPS: ReadonlySet<string> = new Set(["group.create", "group.rename", "group.add_workspace", "group.archive"])
/** Workspaces one group holds in slice 1; more is refused, never truncated. */
export const GROUP_MAX_ITEMS = 500

type Role = "owner" | "edit" | "view"
type Placement = typeof CloudGroupItem.Type.placement
export interface GroupRow {
  readonly id: string
  readonly name: string
  readonly created_by: string
  readonly created_at: number
  readonly archived: boolean
  readonly default_placement: Placement["kind"]
  readonly item_count: number
  /** The next item position (positions are never reused, so order is stable). */
  readonly next_position: number
  readonly members: Readonly<Record<string, Role>>
}
type ItemRow = typeof CloudGroupItem.Type & { readonly group: string }

const isGroupId = Schema.is(GroupId)

export const groupOf = (rows: RowReader | undefined, id: string): GroupRow | undefined => (isGroupId(id) ? rows?.get<GroupRow>(TABLE_GROUP, id)?.row : undefined)
export const roleIn = (g: GroupRow, user: string | undefined): Role | undefined => (user === undefined ? undefined : g.members[user])
export const groupView = (g: GroupRow, user: string): typeof CloudGroup.Type => ({
  id: g.id,
  name: g.name,
  created_by: g.created_by,
  created_at: g.created_at,
  archived: g.archived,
  default_placement: g.default_placement,
  item_count: g.item_count,
  role: g.members[user] ?? "view"
})
export const groupLinks = (id: string) => ({ link: `${GROUP_LINK_PREFIX}${id}`, web_link: `${GROUP_WEB_LINK_PREFIX}${id}` })

const put = (table: string, key: string, row: unknown): RowWrite => ({ table, op: "upsert", key, n: null, row })

type Reduced = { ok: true; state: TeamState; value: unknown; changed?: boolean; writes?: ReadonlyArray<RowWrite> } | ReturnType<typeof reject>

/** The group the caller owns, or the refusal (missing and not-a-member answer the same, so ids do not leak). */
const owned = (ctx: ReduceContext, id: string): { ok: true; g: GroupRow } | ReturnType<typeof reject> => {
  const g = groupOf(ctx.rows, id)
  const role = g ? roleIn(g, ctx.principal.user) : undefined
  if (!g || !role) return reject("selector.not_found", "no such group")
  if (role !== "owner") return reject("auth.forbidden", "only the group's owner may change it")
  return { ok: true, g }
}

export const reduceGroup = (state: TeamState, op: string, params: unknown, ctx: ReduceContext): Reduced => {
  if (!state.team) return reject("validation.invalid", "team not initialized")
  const user = ctx.principal.user
  if (!user) return reject("auth.forbidden", "cloud groups need a person (a session or that person's install)")
  switch (op) {
    case "group.create": {
      // The id is the server's: a caller that sends one is refused, not silently ignored.
      if (params && typeof params === "object" && "id" in params) return reject("validation.invalid", "the server picks a group's id")
      const d = decodeParams<typeof GroupCreate.params.Type>(GroupCreate, params)
      if (!d.ok) return d
      const id = ctx.newId("grp")
      const g: GroupRow = { id, name: d.value.name, created_by: user, created_at: ctx.now, archived: false, default_placement: d.value.default_placement ?? "local", item_count: 0, next_position: 0, members: { [user]: "owner" } }
      return { ok: true, state, value: groupView(g, user), writes: [put(TABLE_GROUP, id, g), put(TABLE_GROUP_MEMBER, `${user}:${id}`, { group: id, role: "owner" })] }
    }
    case "group.rename": {
      const d = decodeParams<typeof GroupRename.params.Type>(GroupRename, params)
      if (!d.ok) return d
      const o = owned(ctx, d.value.group)
      if (!o.ok) return o
      if (o.g.name === d.value.name) return { ok: true, state, value: groupView(o.g, user), changed: false }
      const g = { ...o.g, name: d.value.name }
      return { ok: true, state, value: groupView(g, user), writes: [put(TABLE_GROUP, g.id, g)] }
    }
    case "group.archive": {
      const d = decodeParams<typeof GroupArchive.params.Type>(GroupArchive, params)
      if (!d.ok) return d
      const o = owned(ctx, d.value.group)
      if (!o.ok) return o
      if (o.g.archived) return { ok: true, state, value: groupView(o.g, user), changed: false }
      const g = { ...o.g, archived: true }
      return { ok: true, state, value: groupView(g, user), writes: [put(TABLE_GROUP, g.id, g)] }
    }
    case "group.add_workspace": {
      const d = decodeParams<typeof GroupAddWorkspace.params.Type>(GroupAddWorkspace, params)
      if (!d.ok) return d
      const o = owned(ctx, d.value.group)
      if (!o.ok) return o
      if (o.g.archived) return reject("validation.invalid", "the group is archived")
      const ws = d.value.workspace
      const holder = ctx.rows?.get<{ group: string }>(TABLE_GROUP_WS, ws)?.row.group
      if (holder !== undefined && holder !== o.g.id) return reject("conflict", "the workspace is in another cloud group")
      const prior = holder === o.g.id ? ctx.rows?.get<ItemRow>(TABLE_GROUP_ITEM, `${o.g.id}:${ws}`)?.row : undefined
      if (!prior && o.g.item_count >= GROUP_MAX_ITEMS) return reject("validation.invalid", `a cloud group holds at most ${GROUP_MAX_ITEMS} workspaces`)
      const item: ItemRow = {
        group: o.g.id,
        workspace: ws,
        ...(d.value.title !== undefined ? { title: d.value.title } : prior?.title !== undefined ? { title: prior.title } : {}),
        placement: d.value.placement,
        position: prior?.position ?? o.g.next_position,
        added_by: prior?.added_by ?? user,
        added_at: prior?.added_at ?? ctx.now
      }
      const { group: _g, ...value } = item
      if (prior && JSON.stringify(prior) === JSON.stringify(item)) return { ok: true, state, value, changed: false }
      const g = prior ? o.g : { ...o.g, item_count: o.g.item_count + 1, next_position: o.g.next_position + 1 }
      const writes = [put(TABLE_GROUP_ITEM, `${o.g.id}:${ws}`, item), ...(prior ? [] : [put(TABLE_GROUP_WS, ws, { group: o.g.id }), put(TABLE_GROUP, g.id, g)])]
      return { ok: true, state, value, writes }
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/** A group's workspaces in position order (at most GROUP_MAX_ITEMS rows, read by key range). */
export const groupItems = (rows: (RowReader & { keyRange?: <T>(t: string, q: { after?: string; before?: string; limit: number }) => Array<{ row: T }> }) | undefined, id: string): Array<typeof CloudGroupItem.Type> =>
  (rows?.keyRange?.<ItemRow>(TABLE_GROUP_ITEM, { after: `${id}:`, before: `${id};`, limit: GROUP_MAX_ITEMS }) ?? [])
    .map((r) => {
      const { group: _g, ...item } = r.row
      return item
    })
    .sort((a, b) => a.position - b.position)
