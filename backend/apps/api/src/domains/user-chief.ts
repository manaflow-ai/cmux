import { createHash } from "node:crypto"
import { conversation as homeConversation, invites, user as homeUser } from "@cmux/home-core"
import type { OutboxItem, ReduceContext, ReduceResult } from "@cmux/ownership"
import type { UserState } from "./user.ts"

/**
 * Chief records in UserDO (plans/cmux-next/chief-mac.md section 9). The user's principal is
 * the only writer, through chief.create, chief.update and chief.archive. Exactly one active
 * chief is the default. A new chief's MuxDO is bound (mux.bind) and receives the user's text
 * confirmation level (mux.text_confirm.level.sync) through the outbox. Archived chiefs stay
 * restorable for 30 days; after that only a tombstone {id, owner_user, archived_at} is kept,
 * so an id is never reused.
 */
export interface ChiefRecord {
  readonly id: string
  readonly owner_user: string
  readonly display_name: string
  readonly is_default: boolean
  readonly brain: "cloud"
  readonly main_conversation: string | null
  readonly harness: string | null
  readonly rev: number
  readonly created_at: string
  readonly updated_at: string
  readonly archived_at: string | null
}
export interface ChiefTombstone {
  readonly id: string
  readonly owner_user: string
  readonly archived_at: string
}
export interface ChiefsState {
  readonly chiefs?: Readonly<Record<string, ChiefRecord>>
  readonly chief_tombstones?: Readonly<Record<string, ChiefTombstone>>
}

export const CHIEF_OPS = new Set(["chief.create", "chief.update", "chief.archive"])
export const RESTORE_WINDOW_MS = 30 * 24 * 3_600_000
const MAX_CHIEFS = 20

type Params = Record<string, unknown>
const reject = (code: string, message = code): ReduceResult<UserState> => ({ ok: false, code, message })
const nameOk = (v: unknown): v is string => typeof v === "string" && v.trim().length >= 1 && v.length <= 100

/** Active chiefs' ids (the ones that receive the text confirmation level). */
export const activeChiefs = (state: UserState): ReadonlyArray<string> => Object.values(state.chiefs ?? {}).filter((c) => c.archived_at === null).map((c) => c.id)

/** Archived chiefs past the restore window become tombstones (applied on every chief op and on list). */
export const compactChiefs = (state: UserState, now: number): UserState => {
  const chiefs = state.chiefs ?? {}
  const expired = Object.values(chiefs).filter((c) => c.archived_at !== null && Date.parse(c.archived_at) + RESTORE_WINDOW_MS <= now)
  if (expired.length === 0) return state
  const rest = Object.fromEntries(Object.entries(chiefs).filter(([id]) => !expired.some((c) => c.id === id)))
  const tombs = { ...(state.chief_tombstones ?? {}), ...Object.fromEntries(expired.map((c) => [c.id, { id: c.id, owner_user: c.owner_user, archived_at: c.archived_at! }])) }
  return { ...state, chiefs: rest, chief_tombstones: tombs }
}

/** The current level for a new or restored chief; none while the level was never set (rev 0: chiefs read strict). */
const levelSync = (state: UserState, agent: string): Array<OutboxItem> => {
  const confirm = state.confirm ?? homeUser.EMPTY_USER_CONFIRM
  if (confirm.rev === 0) return []
  return [{
    kind: "mux.text_confirm.level.sync",
    entity: `level:${state.user?.id}:${confirm.rev}:${agent}`,
    payload: { level: homeUser.userLevelOf(confirm), rev: confirm.rev },
    target: { class: "MuxDO", name: agent, coalesce: "text_confirm_level" }
  }]
}

export const reduceChief = (stateIn: UserState, op: string, params: Params, ctx: ReduceContext): ReduceResult<UserState> => {
  const owner = stateIn.user?.id
  if (!owner) return reject("validation.invalid", "call user.ensure first")
  const now = formatNow(ctx.now)
  const state = compactChiefs(stateIn, ctx.now)
  const chiefs = state.chiefs ?? {}
  const active = Object.values(chiefs).filter((c) => c.archived_at === null)
  const commit = (next: Record<string, ChiefRecord>, value: ChiefRecord, outbox: Array<OutboxItem> = []): ReduceResult<UserState> => ({
    ok: true,
    state: { ...state, chiefs: next },
    value,
    outbox
  })
  const clearDefault = (all: Record<string, ChiefRecord>, keep: string) =>
    Object.fromEntries(Object.entries(all).map(([id, c]) => [id, c.is_default && id !== keep ? { ...c, is_default: false, rev: c.rev + 1, updated_at: now } : c]))

  switch (op) {
    case "chief.create": {
      if (params.display_name !== undefined && !nameOk(params.display_name)) return reject("validation.invalid", "display_name must be 1 to 100 characters")
      if (params.is_default !== undefined && typeof params.is_default !== "boolean") return reject("validation.invalid", "is_default must be a boolean")
      if (active.length >= MAX_CHIEFS) return reject("validation.invalid", `at most ${MAX_CHIEFS} chiefs`)
      const id = `agent_${invites.crockford(createHash("sha256").update(`chief\u0000${owner}\u0000${ctx.tx}`).digest(), 26)}`
      if (chiefs[id] || state.chief_tombstones?.[id]) return reject("validation.invalid", "chief id collision")
      const isDefault = active.length === 0 || params.is_default === true
      const record: ChiefRecord = {
        id,
        owner_user: owner,
        display_name: typeof params.display_name === "string" ? params.display_name.trim() : "Chief",
        is_default: isDefault,
        brain: "cloud",
        main_conversation: null,
        harness: null,
        rev: 1,
        created_at: now,
        updated_at: now,
        archived_at: null
      }
      const next = { ...(isDefault ? clearDefault({ ...chiefs }, id) : chiefs), [id]: record }
      const bind: OutboxItem = { kind: "mux.bind", entity: `bind:${id}`, payload: { agent: id, owner_user: owner, brain: "cloud" }, target: { class: "MuxDO", name: id } }
      return commit(next, record, [bind, ...levelSync(state, id)])
    }
    case "chief.update": {
      const cur = typeof params.chief === "string" ? chiefs[params.chief] : undefined
      if (!cur) return reject("selector.not_found", state.chief_tombstones?.[String(params.chief)] ? "chief_expired" : "chief not found")
      if (params.expected_rev !== cur.rev) return reject("revision.conflict", `expected_rev ${String(params.expected_rev)} does not match ${cur.rev}`)
      const restore = params.archived === false
      if (params.archived !== undefined && !restore) return reject("validation.invalid", "archived accepts only false (restore); use chief.archive")
      if (cur.archived_at !== null && !restore) return reject("chief_archived", "restore the chief first")
      if (params.display_name !== undefined && !nameOk(params.display_name)) return reject("validation.invalid", "display_name must be 1 to 100 characters")
      if (params.is_default !== undefined && params.is_default !== true) return reject("validation.invalid", "is_default accepts only true; make another chief the default")
      if (params.harness !== undefined && params.harness !== null && (typeof params.harness !== "string" || params.harness.length > 64)) return reject("validation.invalid", "harness must be a short string or null")
      if (restore && active.length >= MAX_CHIEFS) return reject("validation.invalid", `at most ${MAX_CHIEFS} chiefs`)
      const updated: ChiefRecord = {
        ...cur,
        ...(typeof params.display_name === "string" ? { display_name: params.display_name.trim() } : {}),
        ...(params.harness !== undefined ? { harness: params.harness as string | null } : {}),
        ...(restore ? { archived_at: null } : {}),
        is_default: params.is_default === true ? true : cur.is_default,
        rev: cur.rev + 1,
        updated_at: now
      }
      const next = { ...(params.is_default === true ? clearDefault({ ...chiefs }, cur.id) : chiefs), [cur.id]: updated }
      // A restored chief gets the current level again (it missed syncs while archived).
      return commit(next, updated, restore ? levelSync(state, cur.id) : [])
    }
    case "chief.archive": {
      const cur = typeof params.chief === "string" ? chiefs[params.chief] : undefined
      if (!cur) return reject("selector.not_found", "chief not found")
      if (params.expected_rev !== cur.rev) return reject("revision.conflict", `expected_rev ${String(params.expected_rev)} does not match ${cur.rev}`)
      if (cur.is_default) return reject("chief_is_default", "make another chief the default first")
      if (cur.archived_at !== null) return { ok: true, state, value: cur, changed: false }
      const archived: ChiefRecord = { ...cur, archived_at: now, rev: cur.rev + 1, updated_at: now }
      return commit({ ...chiefs, [cur.id]: archived }, archived)
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/** chief.list: active chiefs first (default first), archived on request, tombstones. */
export const chiefList = (stateIn: UserState, now: number, includeArchived: boolean) => {
  const state = compactChiefs(stateIn, now)
  const all = Object.values(state.chiefs ?? {})
  const sorted = all
    .filter((c) => includeArchived || c.archived_at === null)
    .sort((a, b) => Number(b.archived_at === null) - Number(a.archived_at === null) || Number(b.is_default) - Number(a.is_default) || a.created_at.localeCompare(b.created_at))
  return { chiefs: sorted, tombstones: Object.values(state.chief_tombstones ?? {}) }
}

const formatNow = (ms: number) => homeConversation.formatRfc3339Millis(ms)
