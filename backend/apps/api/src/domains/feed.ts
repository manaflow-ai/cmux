import type { Domain, ReduceContext, ReduceResult } from "@cmux/ownership"
import { checkAnswer, FeedAnswer, FeedArchive, FeedCancel, FeedPrefsSet, FeedRead, FeedSnooze, type FeedItem } from "@cmux/protocol"
import { admit, decodeParams, reject } from "./common.ts"
import { reduceAdopt, reduceAdoptCancel, reducePost } from "./feed-post.ts"
import { approvalDecision, integrationPoster } from "./feed-approvals.ts"
import { matchesFilter, type FeedFilterValue } from "./feed-query.ts"
import {
  ADOPT_TOMBSTONE_MS,
  claimDedupe,
  initialFeedState,
  isActive,
  isUserClient,
  posterScope,
  prunableAt,
  pushDueAt,
  pushEligible,
  releaseDedupe,
  RETENTION_MS,
  touch,
  type FeedState
} from "./feed-state.ts"

export { initialFeedState, nextFeedWake, visibleTo, type FeedState } from "./feed-state.ts"

type Result = ReduceResult<FeedState>
type Item = FeedItem

const userOnly = new Set(["feed.read", "feed.seen", "feed.archive", "feed.unarchive", "feed.snooze", "feed.prefs.set", "feed.answer"])
const SYSTEM_OPS = new Set(["feed.expire", "feed.snooze_wake", "feed.prune", "feed.push_due"])

const closedReject = (item: Item, why: string) => ({ ...reject("feed.closed", why, { item }), retryable: false })

const withItems = (state: FeedState, changed: ReadonlyArray<Item>, dedupe = state.dedupe): FeedState => {
  const items = { ...state.items }
  for (const i of changed) items[i.id] = i
  return { ...state, items, dedupe }
}

const lookup = (state: FeedState, ids: ReadonlyArray<string>): { ok: true; items: Array<Item> } | ({ ok: false } & ReturnType<typeof reject>) => {
  const items: Array<Item> = []
  for (const id of ids) {
    const i = state.items[id]
    if (!i) return reject("selector.not_found", `no feed item ${id}`, { item: id })
    items.push(i)
  }
  return { ok: true, items }
}

/** Applies `fn` to each item; unchanged items (fn returns null) are skipped. */
const triageEach = (state: FeedState, items: ReadonlyArray<Item>, fn: (i: Item) => Item | null, dedupeFn?: (d: FeedState["dedupe"], before: Item, after: Item) => FeedState["dedupe"]): Result => {
  const changed: Array<Item> = []
  let dedupe = state.dedupe
  for (const i of items) {
    const next = fn(i)
    if (next) {
      changed.push(next)
      if (dedupeFn) dedupe = dedupeFn(dedupe, i, next)
    }
  }
  const ref = (s: FeedState) => ({ items: items.map((i) => ({ id: i.id, revision: s.items[i.id]!.revision })) })
  if (changed.length === 0) return { ok: true, state, value: ref(state), changed: false }
  const next = withItems(state, changed, dedupe)
  return { ok: true, state: next, value: ref(next) }
}

const reduceAnswer = (state: FeedState, params: unknown, ctx: ReduceContext): Result => {
  const d = decodeParams<typeof FeedAnswer.params.Type>(FeedAnswer, params)
  if (!d.ok) return d
  const item = state.items[d.value.item]
  if (!item) return reject("selector.not_found", `no feed item ${d.value.item}`)
  if (item.type !== "request") return reject("validation.invalid", "a notice takes no answer")
  if (item.state !== "open") return closedReject(item, `the request is already ${item.state}`)
  if (ctx.now >= item.expires_at) return closedReject(item, "the request expired")
  // The person answers, never an agent (no self-approval), and only from a user action.
  if (ctx.origin !== "user") return reject("auth.forbidden", "answers come only from a user action (origin user)")
  // Sign-in, passkey and Mac handoffs are completed in the Mac pane that holds the context, never typed elsewhere.
  if (item.needs_mac && ctx.principal.install_kind !== "mac") return reject("auth.forbidden", "this request is answered on the Mac that holds its context")
  // An integration approval (G8) is answered only by the person's own session, never by an install an app or agent could drive.
  if (item.poster.kind === "integration" && ctx.principal.kind !== "session") return reject("auth.forbidden", "approve this request in the cmux web dashboard, signed in with your account")
  const r = checkAnswer(item.kind, item.prompt, item.answer_schema, d.value.answer)
  if (!r.ok) return reject("validation.invalid", r.message)
  const next = touch(item, ctx.now, {
    state: "answered",
    answer: { value: d.value.answer, by: ctx.principal.identity, device: d.value.device ?? null, at: ctx.now },
    closed_at: ctx.now,
    read_at: item.read_at ?? ctx.now,
    push_due_at: null
  })
  const decision = (d.value.answer as { decision?: unknown } | null)?.decision === "allow" ? "allow" : "deny"
  return { ok: true, state: withItems(state, [next], releaseDedupe(state.dedupe, item)), value: { item: next }, outbox: approvalDecision(next, decision, ctx.principal.sso_team) }
}

const reduceCancel = (state: FeedState, params: unknown, ctx: ReduceContext): Result => {
  const d = decodeParams<typeof FeedCancel.params.Type>(FeedCancel, params)
  if (!d.ok) return d
  const item = state.items[d.value.item]
  if (!item) return reject("selector.not_found", `no feed item ${d.value.item}`)
  const p = ctx.principal
  // The person declines anything; a poster (its scope, or the daemon install that posted for an agent) withdraws its own.
  const byUser = isUserClient(p) && ctx.origin === "user"
  const byPoster = item.poster.scope === posterScope(p) || (p.install !== undefined && !p.agent && item.poster.install === p.install)
  if (!byUser && !byPoster) return reject("auth.forbidden", "only the poster or the user may cancel this item")
  const reason = d.value.reason ?? (byUser && !byPoster ? "declined" : "poster")
  if (reason === "declined" && !byUser) return reject("auth.forbidden", "only the user declines")
  if (reason !== "declined" && !byPoster) return reject("auth.forbidden", "the user cancels by declining")
  if (item.state !== "open") {
    if (item.state === "cancelled" && item.cancel?.reason === reason) return { ok: true, state, value: { item }, changed: false }
    return closedReject(item, `the item is already ${item.state}`)
  }
  const next = touch(item, ctx.now, {
    state: "cancelled",
    cancel: { reason, by: p.identity, at: ctx.now, note: d.value.note ?? null },
    closed_at: ctx.now,
    push_due_at: null
  })
  // A declined integration approval is a final deny for the waiting op (G8).
  return { ok: true, state: withItems(state, [next], releaseDedupe(state.dedupe, item)), value: { item: next }, ...(reason === "declined" ? { outbox: approvalDecision(next, "deny") } : {}) }
}

const reduceTriage = (state: FeedState, op: string, params: unknown, ctx: ReduceContext): Result => {
  const now = ctx.now
  if (op === "feed.read") {
    const d = decodeParams<typeof FeedRead.params.Type>(FeedRead, params)
    if (!d.ok) return d
    const forms = [d.value.items !== undefined, d.value.all === true, d.value.filter !== undefined].filter(Boolean).length
    if (forms !== 1) return reject("validation.invalid", "give exactly one of items, all or filter")
    const unread = Object.values(state.items).filter((i) => i.read_at === null)
    const found = d.value.items ? lookup(state, d.value.items) : { ok: true as const, items: d.value.filter ? unread.filter((i) => matchesFilter(i, d.value.filter!)) : unread }
    if (!found.ok) return found
    return triageEach(state, found.items, (i) => (i.read_at === null ? touch(i, now, { read_at: now, push_due_at: i.type === "notice" ? null : i.push_due_at }) : null))
  }
  if (op === "feed.archive") {
    const d = decodeParams<typeof FeedArchive.params.Type>(FeedArchive, params)
    if (!d.ok) return d
    if ((d.value.items === undefined) === (d.value.filter === undefined)) return reject("validation.invalid", "give items or filter, not both")
  }
  const v = (params ?? {}) as { items?: ReadonlyArray<string>; filter?: FeedFilterValue }
  let found: ReturnType<typeof lookup>
  if (op === "feed.archive" && v.filter !== undefined && v.items === undefined) {
    if (typeof v.filter !== "object" || v.filter === null) return reject("validation.invalid", "filter must be an object")
    // A filter archives what it can: open requests are skipped, never refused.
    found = { ok: true, items: Object.values(state.items).filter((i) => i.archived_at === null && !(i.type === "request" && i.state === "open") && matchesFilter(i, v.filter!)) }
  } else {
    const ids = v.items
    if (!Array.isArray(ids) || ids.length === 0 || ids.length > 256 || !ids.every((x) => typeof x === "string")) return reject("validation.invalid", "items must list 1 to 256 item ids")
    found = lookup(state, ids)
  }
  if (!found.ok) return found
  const openRequest = found.items.find((i) => i.type === "request" && i.state === "open")
  switch (op) {
    case "feed.seen":
      return triageEach(state, found.items, (i) => (i.seen_at === null ? touch(i, now, { seen_at: now, push_due_at: null }) : null))
    case "feed.archive":
      if (openRequest) return reject("validation.invalid", "answer or decline an open request; it cannot be archived", { item: openRequest.id })
      return triageEach(
        state,
        found.items,
        (i) => (i.archived_at === null ? touch(i, now, { archived_at: now, read_at: i.read_at ?? now, snoozed_until: null, push_due_at: null }) : null),
        (dd, before) => releaseDedupe(dd, before)
      )
    case "feed.unarchive":
      return triageEach(state, found.items, (i) => (i.archived_at !== null ? touch(i, now, { archived_at: null }) : null), (dd, _b, after) => claimDedupe(dd, after))
    case "feed.snooze": {
      const d = decodeParams<{ readonly items: ReadonlyArray<string>; readonly until: number }>(FeedSnooze, params)
      if (!d.ok) return d
      if (openRequest) return reject("validation.invalid", "answer or decline an open request; it cannot be snoozed", { item: openRequest.id })
      if (d.value.until <= now) return reject("validation.invalid", "until must be in the future")
      return triageEach(state, found.items, (i) => (i.snoozed_until === d.value.until ? null : touch(i, now, { snoozed_until: d.value.until, push_due_at: null })))
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

const reducePrefs = (state: FeedState, params: unknown, ctx: ReduceContext): Result => {
  const d = decodeParams<typeof FeedPrefsSet.params.Type>(FeedPrefsSet, params)
  if (!d.ok) return d
  const prefs = {
    push_enabled: d.value.push_enabled ?? state.prefs.push_enabled,
    push_delay: { ...state.prefs.push_delay, ...(d.value.push_delay ?? {}) },
    push_skip_when_mac_active: d.value.push_skip_when_mac_active ?? state.prefs.push_skip_when_mac_active
  }
  if (JSON.stringify(prefs) === JSON.stringify(state.prefs)) return { ok: true, state, value: { prefs }, changed: false }
  // Pushes already scheduled follow the new rules: a disabled priority loses its pending push.
  const cancelled = Object.values(state.items).filter((i) => i.push_due_at !== null && (!prefs.push_enabled || prefs.push_delay[i.priority] === null))
  const items = { ...state.items }
  for (const i of cancelled) items[i.id] = touch(i, ctx.now, { push_due_at: null })
  return { ok: true, state: { ...state, prefs, items }, value: { prefs } }
}

/** The owner's alarm ops. Each re-checks state, so a repeated alarm changes nothing. */
const reduceSystem = (state: FeedState, op: string, params: unknown, ctx: ReduceContext): Result => {
  const at = (params as { at?: unknown; before?: unknown } | null)?.[op === "feed.prune" ? "before" : "at"]
  // Only the owner's alarm calls these, with its own clock reading; decisions use `at`, never a client time.
  if (typeof at !== "number" || !Number.isInteger(at)) return reject("validation.invalid", "system op time must be an integer")
  const all = Object.values(state.items)
  switch (op) {
    case "feed.expire": {
      const due = all.filter((i) => i.state === "open" && i.expires_at <= at)
      let dedupe = state.dedupe
      const changed = due.map((i) => {
        dedupe = releaseDedupe(dedupe, i)
        return touch(i, ctx.now, { state: "expired", closed_at: i.expires_at, push_due_at: null })
      })
      return changed.length === 0 ? { ok: true, state, value: { items: [] }, changed: false } : { ok: true, state: withItems(state, changed, dedupe), value: { items: changed.map((i) => i.id) } }
    }
    case "feed.snooze_wake": {
      const due = all.filter((i) => i.snoozed_until !== null && i.snoozed_until <= at)
      const changed = due.map((i) => {
        const woke = { ...i, snoozed_until: null, read_at: null, seen_at: null }
        return touch(i, ctx.now, { snoozed_until: null, read_at: null, seen_at: null, push_due_at: pushEligible(woke) ? pushDueAt(state.prefs, i.priority, at) : null })
      })
      return changed.length === 0 ? { ok: true, state, value: { items: [] }, changed: false } : { ok: true, state: withItems(state, changed), value: { items: changed.map((i) => i.id) } }
    }
    case "feed.prune": {
      // `before` is the end-time cutoff: items closed or archived before it go (they stay RETENTION_MS).
      const gone = all.filter((i) => {
        const t = prunableAt(i)
        return t !== null && t - RETENTION_MS <= at
      })
      const tombstones = Object.entries(state.adopt_cancelled ?? {})
      const liveTombstones = tombstones.filter(([, t]) => t.at + ADOPT_TOMBSTONE_MS > at)
      if (gone.length === 0 && liveTombstones.length === tombstones.length) return { ok: true, state, value: { items: [] }, changed: false }
      const items = { ...state.items }
      let dedupe = state.dedupe
      for (const i of gone) {
        dedupe = releaseDedupe(dedupe, i)
        delete items[i.id]
      }
      const adopt_cancelled = liveTombstones.length === tombstones.length ? state.adopt_cancelled : Object.fromEntries(liveTombstones)
      return { ok: true, state: { ...state, items, dedupe, ...(adopt_cancelled === undefined ? {} : { adopt_cancelled }) }, value: { items: gone.map((i) => i.id) } }
    }
    case "feed.push_due": {
      const v = params as { send?: unknown; skip?: unknown }
      if (!Array.isArray(v.send) || !Array.isArray(v.skip)) return reject("validation.invalid", "send and skip are item id lists")
      const sendSet = new Set(v.send as Array<string>)
      const decided = all.filter((i) => i.push_due_at !== null && i.push_due_at <= at && (sendSet.has(i.id) || (v.skip as Array<string>).includes(i.id)))
      const changed = decided.map((i) =>
        sendSet.has(i.id) && pushEligible(i) ? touch(i, ctx.now, { push_due_at: null, pushed_at: at }) : touch(i, ctx.now, { push_due_at: null })
      )
      const sent = changed.filter((i) => i.pushed_at === at).map((i) => i.id)
      return changed.length === 0 ? { ok: true, state, value: { sent: [] }, changed: false } : { ok: true, state: withItems(state, changed), value: { sent } }
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/**
 * FeedDO's reducer (plans/cmux-next/feed.md sections 3 to 6). Pure: the owner,
 * mirror replay and the local feed server's conformance vectors run it.
 */
export const feedDomain: Domain<FeedState> = {
  initial: initialFeedState,

  authorize: (state, op, _params, principal) => {
    if (SYSTEM_OPS.has(op)) return principal.kind === "system" ? undefined : { code: "auth.forbidden", message: `${op} is internal` }
    // The owner's own UserDO posts security notices (FeedDO.systemPrincipal sets `user` only for
    // the stream user:<feed user>); no other system source posts, and a system post is no grant.
    if (principal.kind === "system") {
      // A team's ConnectionDO posts approval requests (G8, FeedDO.integrationApproval stamps `user`).
      const poster = principal.identity === `system:user:${principal.user}` || integrationPoster(principal) !== null
      if (op !== "feed.post" || !principal.user || !poster) return { code: "auth.forbidden", message: `${op} is not open to system principals` }
      return state.user && principal.user !== state.user ? { code: "auth.forbidden", message: "not this user's feed" } : undefined
    }
    if (state.user && principal.user !== state.user) return { code: "auth.forbidden", message: "not this user's feed" }
    if (userOnly.has(op) && !isUserClient(principal)) return { code: "auth.forbidden", message: `${op} is for the user's own clients, not agents` }
    // The grant lives in UserDO; the Worker resolves it per call and passes the classes (as for TeamDO).
    return admit("cloud:FeedDO", op, principal, (p) => (p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined), Date.now())
  },

  reduce: (stateIn, op, params, ctx) => {
    const p = ctx.principal
    const owner = p.kind !== "system" || p.identity === `system:user:${p.user}`
    const state = stateIn.user === null && owner && p.user ? { ...stateIn, user: p.user } : stateIn
    switch (op) {
      case "feed.post":
        return reducePost(state, params, ctx)
      case "feed.adopt":
        return reduceAdopt(state, params, ctx)
      case "feed.adopt.cancel":
        return reduceAdoptCancel(state, params, ctx)
      case "feed.answer":
        return reduceAnswer(state, params, ctx)
      case "feed.cancel":
        return reduceCancel(state, params, ctx)
      case "feed.read":
      case "feed.seen":
      case "feed.archive":
      case "feed.unarchive":
      case "feed.snooze":
        return reduceTriage(state, op, params, ctx)
      case "feed.prefs.set":
        return reducePrefs(state, params, ctx)
      default:
        return SYSTEM_OPS.has(op) ? reduceSystem(state, op, params, ctx) : reject("validation.invalid", `unknown op ${op}`)
    }
  }
}

/** Active (not archived, not snoozed) unread items and open requests, for badges. */
export const feedCounts = (state: FeedState, now: number) => {
  const by_priority: Record<string, number> = {}
  const by_poster_kind: Record<string, number> = {}
  let open_requests = 0
  let unread = 0
  for (const i of Object.values(state.items)) {
    if (i.type === "request" && i.state === "open") {
      open_requests++
      by_priority[i.priority] = (by_priority[i.priority] ?? 0) + 1
    }
    if (isActive(i) && i.read_at === null && (i.snoozed_until === null || i.snoozed_until <= now)) {
      unread++
      by_poster_kind[i.poster.kind] = (by_poster_kind[i.poster.kind] ?? 0) + 1
    }
  }
  return { open_requests, unread, by_priority, by_poster_kind }
}
