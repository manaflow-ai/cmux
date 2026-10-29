import { createHash } from "node:crypto"
import { conversation as homeConversation, invites, user as homeUser } from "@cmux/home-core"
import type { OutboxItem, ReduceContext, ReduceResult } from "@cmux/ownership"
import type { UserState } from "./user.ts"

/** A chief's main conversation id: derived from the chief id (one place per chief). */
export const chiefMainConversation = (chief: string): string => `conv_${invites.crockford(createHash("sha256").update(`chief-main\u0000${chief}`).digest(), 26)}`

/**
 * Chief records in UserDO (plans/cmux-next/chief-mac.md section 9). The user's principal is
 * the only writer, through chief.create, chief.update, chief.archive and chief.delete. Exactly one active
 * chief is the default. A new chief's MuxDO is bound (mux.bind) and receives the user's text
 * confirmation level (mux.text_confirm.level.sync) through the outbox. Archived chiefs stay
 * restorable for 30 days; after that only a tombstone {id, owner_user, archived_at} is kept,
 * so an id is never reused. chief.delete skips the window: the record becomes that tombstone at once
 * (active or archived, never the default). Each chief gets one main conversation (kind chief, created by the
 * system through the outbox, id derived from the chief id); a DM with your own chief opens it.
 */
/** A paired server running the chief's brain (G8): its team host and its daemon install. */
export interface ChiefBrainPlace {
  readonly host: string
  readonly install: string
}
export interface ChiefRecord {
  readonly id: string
  readonly owner_user: string
  readonly display_name: string
  readonly is_default: boolean
  readonly brain: "cloud"
  /** Null when no server is named; absent on records written before G8 (read as null). */
  readonly brain_place?: ChiefBrainPlace | null
  readonly main_conversation: string | null
  readonly harness: string | null
  readonly rev: number
  readonly created_at: string
  readonly updated_at: string
  readonly archived_at: string | null
  /** The chief that created this one with its chiefs grant (brain-chiefs.ts); absent when the user did. */
  readonly created_by?: string
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

export const CHIEF_OPS = new Set(["chief.create", "chief.update", "chief.archive", "chief.delete"])
export const RESTORE_WINDOW_MS = 30 * 24 * 3_600_000
/** A chief's agent class (participant `agent_class`); only this class acts under its owner's reach. */
export const CHIEF_AGENT_CLASS = "mux"
const MAX_CHIEFS = 20

type Params = Record<string, unknown>
const reject = (code: string, message = code): ReduceResult<UserState> => ({ ok: false, code, message })
const nameOk = (v: unknown): v is string => typeof v === "string" && v.trim().length >= 1 && v.length <= 100
const HOST_ID = /^host_[a-z0-9]{20}$/

/**
 * Checks a requested brain place: the user's session only, a host id, and a live daemon install
 * (a paired server) of this user. Returns the place, or a rejection.
 */
const brainPlace = (state: UserState, raw: unknown, ctx: ReduceContext): ChiefBrainPlace | ReduceResult<UserState> => {
  if (ctx.principal.kind !== "session") return reject("auth.forbidden", "only the user's session places a chief's brain")
  const v = raw as { host?: unknown; install?: unknown } | null
  if (!v || typeof v !== "object" || typeof v.host !== "string" || !HOST_ID.test(v.host) || typeof v.install !== "string") {
    return reject("validation.invalid", "brain_place needs {host, install}")
  }
  const inst = state.installs[v.install]
  if (!inst || inst.revoked_at !== null || inst.kind !== "daemon") return reject("validation.invalid", "brain_place.install must be a live paired server install")
  return { host: v.host, install: v.install }
}
const isReject = (v: ChiefBrainPlace | ReduceResult<UserState>): v is ReduceResult<UserState> => "ok" in v

/**
 * The placed server acts as its chief with the chief's rights (G8): a chief token of the install
 * that the chief's brain_place names also covers mutate-shared. Nothing else widens a grant.
 */
export const chiefGrantClasses = (state: UserState, install: string, agent: string | undefined, classes: ReadonlyArray<string>): ReadonlyArray<string> => {
  if (agent === undefined) return classes
  const chief = state.chiefs?.[agent]
  if (!chief || chief.archived_at !== null || chief.brain_place?.install !== install || classes.includes("mutate-shared")) return classes
  return [...classes, "mutate-shared"]
}

/** An unarchived chief of this user (a chief token may be minted and used for it). */
export const chiefActive = (state: UserState, agent: string): boolean => {
  const c = state.chiefs?.[agent]
  return c !== undefined && c.archived_at === null && state.user !== null && state.user !== undefined && c.owner_user === state.user.id
}

/**
 * A chief token's classes: undefined for an unknown or archived chief. The server install placed for this chief
 * (brain_place) gets the chief's rights only after TeamDO, the server's authority, confirms the server is still
 * enrolled with no revocation pending (`confirm`, asked on every such request: a revoke in TeamDO counts before
 * its push reaches UserDO); an unconfirmed placed server is refused outright.
 */
export const placedChiefClasses = async (
  state: UserState,
  inst: { readonly bound_team?: string },
  install: string,
  agent: string,
  classes: ReadonlyArray<string>,
  confirm: (team: string, host: string) => Promise<boolean>,
  current: () => UserState = () => state
): Promise<ReadonlyArray<string> | undefined> => {
  if (!chiefActive(state, agent)) return undefined
  const widened = chiefGrantClasses(state, install, agent, classes)
  if (widened === classes) return classes
  const place = state.chiefs?.[agent]?.brain_place
  if (!inst.bound_team || !place || !(await confirm(inst.bound_team, place.host))) return undefined
  // Read again after the await: a revoke, a move or an archive may have committed meanwhile.
  const now = current()
  const still = now.installs?.[install]?.revoked_at === null && chiefActive(now, agent) && now.chiefs?.[agent]?.brain_place?.host === place.host
  return still && chiefGrantClasses(now, install, agent, classes) !== classes ? widened : undefined
}

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
  // Only the user's own session or app install writes chief records; never an agent or a system op,
  // except a Chief with the chiefs grant from its Cloud brain (UserDO.chiefManage, server code only):
  // a create with only a display name, or a rename of another chief (brain-chiefs.ts holds the ceiling).
  const p = ctx.principal
  const viaChief = p.kind === "agent" && p.agent !== undefined && p.user === owner && p.identity === `agent:${p.agent} via chief` && chiefActive(stateIn, p.agent)
  if (viaChief) {
    const keys = Object.keys(params)
    const allowed = op === "chief.create" ? ["display_name"] : op === "chief.update" ? ["chief", "expected_rev", "display_name"] : []
    if (allowed.length === 0 || keys.some((k) => !allowed.includes(k)) || (op === "chief.update" && params.chief === p.agent)) return reject("auth.forbidden", "a Chief creates chiefs and renames other chiefs only")
  } else if ((p.kind !== "session" && p.kind !== "install") || p.agent || p.user !== owner) return reject("auth.forbidden", "only the user writes chief records")
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
      let place: ChiefBrainPlace | null = null
      if (params.brain_place !== undefined) {
        const checked = brainPlace(state, params.brain_place, ctx)
        if (isReject(checked)) return checked
        place = checked
      }
      const id = `agent_${invites.crockford(createHash("sha256").update(`chief\u0000${owner}\u0000${ctx.tx}`).digest(), 26)}`
      if (chiefs[id] || state.chief_tombstones?.[id]) return reject("validation.invalid", "chief id collision")
      const isDefault = active.length === 0 || params.is_default === true
      const record: ChiefRecord = {
        id,
        owner_user: owner,
        display_name: typeof params.display_name === "string" ? params.display_name.trim() : "Chief",
        is_default: isDefault,
        brain: "cloud",
        brain_place: place,
        main_conversation: chiefMainConversation(id),
        harness: null,
        rev: 1,
        created_at: now,
        updated_at: now,
        archived_at: null,
        ...(viaChief ? { created_by: p.agent } : {})
      }
      const next = { ...(isDefault ? clearDefault({ ...chiefs }, id) : chiefs), [id]: record }
      const bind: OutboxItem = { kind: "mux.bind", entity: `bind:${id}`, payload: { agent: id, owner_user: owner, brain: "cloud" }, target: { class: "MuxDO", name: id } }
      // The chief's main conversation (one place per chief): created by the system, the owner and the chief only.
      const main = record.main_conversation!
      const thread: OutboxItem = {
        kind: "conversation.create",
        entity: `chief-main:${id}`,
        payload: {
          id: main,
          kind: "chief",
          owner,
          title: record.display_name,
          participants: [
            { id: owner, kind: "human", display_name: stateIn.user?.display_name ?? "Me" },
            { id, kind: "agent", agent_class: CHIEF_AGENT_CLASS, owner_user: owner, display_name: record.display_name }
          ]
        },
        target: { class: "ConversationDO", name: main }
      }
      return commit(next, record, [bind, thread, ...levelSync(state, id)])
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
      let place: { value: ChiefBrainPlace | null } | undefined
      if (params.brain_place === null) {
        if (p.kind !== "session") return reject("auth.forbidden", "only the user's session places a chief's brain")
        place = { value: null }
      } else if (params.brain_place !== undefined) {
        const checked = brainPlace(state, params.brain_place, ctx)
        if (isReject(checked)) return checked
        place = { value: checked }
      }
      const updated: ChiefRecord = {
        ...cur,
        ...(place ? { brain_place: place.value } : {}),
        ...(typeof params.display_name === "string" ? { display_name: params.display_name.trim() } : {}),
        ...(params.harness !== undefined ? { harness: params.harness as string | null } : {}),
        ...(restore ? { archived_at: null } : {}),
        is_default: params.is_default === true ? true : cur.is_default,
        rev: cur.rev + 1,
        updated_at: now
      }
      const next = { ...(params.is_default === true ? clearDefault({ ...chiefs }, cur.id) : chiefs), [cur.id]: updated }
      // A new name reaches the chief's main conversation too (its title, the chief's name on its messages).
      const renamed: Array<OutboxItem> =
        updated.display_name !== cur.display_name && updated.main_conversation
          ? [{ kind: "chief.rename", entity: `chief-rename:${cur.id}:${updated.rev}`, payload: { chief: cur.id, display_name: updated.display_name }, target: { class: "ConversationDO", name: updated.main_conversation } }]
          : []
      // A restored chief gets the current level again (it missed syncs while archived).
      return commit(next, updated, [...renamed, ...(restore ? levelSync(state, cur.id) : [])])
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
    case "chief.delete": {
      // A replay of a done delete answers the stored result (idempotency key); a new key finds the tombstone.
      const id = typeof params.chief === "string" ? params.chief : undefined
      const cur = id ? chiefs[id] : undefined
      if (!cur) return reject("selector.not_found", id && state.chief_tombstones?.[id] ? "chief_expired" : "chief not found")
      if (params.expected_rev !== cur.rev) return reject("revision.conflict", `expected_rev ${String(params.expected_rev)} does not match ${cur.rev}`)
      if (cur.is_default) return reject("chief_is_default", "make another chief the default first")
      const rest = Object.fromEntries(Object.entries(chiefs).filter(([key]) => key !== cur.id))
      const tomb: ChiefTombstone = { id: cur.id, owner_user: cur.owner_user, archived_at: cur.archived_at ?? now }
      return { ok: true, state: { ...state, chiefs: rest, chief_tombstones: { ...(state.chief_tombstones ?? {}), [cur.id]: tomb } }, value: { ...cur, archived_at: tomb.archived_at }, outbox: [] }
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
    .map((c) => ({ ...c, brain_place: c.brain_place ?? null }))
  return { chiefs: sorted, tombstones: Object.values(state.chief_tombstones ?? {}) }
}

const formatNow = (ms: number) => homeConversation.formatRfc3339Millis(ms)
