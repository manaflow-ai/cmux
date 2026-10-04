import type { Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import { checkAnswer, checkPrompt, FeedAdopt, FeedPost, kindDefaultPriority, kindNeedsMac, type FeedItem } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import {
  claimDedupe,
  DEFAULT_NOTICE_EXPIRY_MS,
  DEFAULT_REQUEST_EXPIRY_MS,
  evictForInsert,
  fitsBudget,
  isActive,
  jsonBytes,
  MAX_INSTALL_POSTS_PER_MINUTE,
  MAX_ITEM_BYTES,
  MAX_OPEN_REQUESTS,
  MAX_POSTS_PER_MINUTE,
  openRequestCount,
  posterScope,
  pushDueAt,
  pushEligible,
  touch,
  type FeedState
} from "./feed-state.ts"

type PostParams = typeof FeedPost.params.Type
type PosterKind = FeedItem["poster"]["kind"]
type Rejected = { ok: false } & ReturnType<typeof reject>

const MAX_EXPIRY_MS = 30 * 24 * 3600_000
/** A deduped notice that was already pushed pushes again only after this long. */
const REPUSH_AFTER_MS = 10 * 60_000

/** The poster kind is declared, but a principal can only claim kinds that fit it. */
const posterKind = (p: Principal, agent: string | undefined, declared: PosterKind | undefined): PosterKind => {
  if (p.kind === "system") return declared === "integration" ? "integration" : "system"
  if (p.kind === "session") return "user"
  const allowed: ReadonlyArray<PosterKind> = agent ? ["agent", "harness", "app", "automation"] : ["agent", "server", "vm", "system"]
  if (declared && allowed.includes(declared)) {
    if (declared === "app" && !agent?.startsWith("app:")) return "agent"
    if (declared === "automation" && !agent?.startsWith("run_")) return "agent"
    // Only a daemon speaks for cmux itself; a CLI or VM token cannot look like cmux.
    if (declared === "system" && p.install_kind !== "daemon") return "server"
    return declared
  }
  return agent ? "agent" : p.install_kind === "vm" ? "vm" : "server"
}

const SAFE_URL = /^(https?|cmux):/i
const unsafeUrl = (v: unknown): boolean => typeof v === "string" && /^[a-z][a-z0-9+.-]*:/i.test(v) && !SAFE_URL.test(v)

const checkUrls = (context: FeedItem["context"] | undefined, open: FeedItem["open"] | undefined): Rejected | undefined => {
  if (context?.url !== undefined && !SAFE_URL.test(context.url)) return reject("validation.invalid", "context.url must be http, https or cmux")
  if (open && Object.values(open.args).some(unsafeUrl)) return reject("validation.invalid", "open arguments may hold only http, https or cmux URLs")
  return undefined
}

const checkShape = (v: Pick<PostParams, "type" | "kind" | "prompt" | "answer_schema" | "actions">): Rejected | undefined => {
  if (v.type === "notice") {
    if (v.kind !== "notice") return reject("validation.invalid", "a notice has kind notice")
    if (v.prompt !== undefined || v.answer_schema !== undefined) return reject("validation.invalid", "a notice has no prompt and no answer_schema")
    if ((v.actions ?? []).some((a) => a.answer !== undefined)) return reject("validation.invalid", "notice actions only open the context")
    return undefined
  }
  if (v.kind === "notice") return reject("validation.invalid", "a request needs a request kind")
  const prompt = checkPrompt(v.kind, v.prompt, v.answer_schema)
  if (!prompt.ok) return reject("validation.invalid", prompt.message)
  for (const a of v.actions ?? []) {
    if (a.answer === undefined) continue
    const r = checkAnswer(v.kind, v.prompt, v.answer_schema, a.answer)
    if (!r.ok) return reject("validation.invalid", `action ${a.id}: ${r.message}`)
  }
  if (new Set((v.actions ?? []).map((a) => a.id)).size !== (v.actions ?? []).length) return reject("validation.invalid", "action ids must be unique")
  return undefined
}

/** Counts one post against the poster scope and its install; refuses beyond either limit. */
const countPost = (state: FeedState, p: Principal, scope: string, now: number): { ok: true; rate: FeedState["rate"] } | Rejected => {
  const minute = Math.floor(now / 60_000)
  const base = p.install ? `base:inst:${p.install}` : `base:${p.identity}`
  const used = (k: string) => (state.rate[k]?.minute === minute ? state.rate[k]!.count : 0)
  if (used(scope) >= MAX_POSTS_PER_MINUTE) return { ...reject("feed.rate_limited", `at most ${MAX_POSTS_PER_MINUTE} posts per minute per poster`), retryable: true }
  if (used(base) >= MAX_INSTALL_POSTS_PER_MINUTE) return { ...reject("feed.rate_limited", `at most ${MAX_INSTALL_POSTS_PER_MINUTE} posts per minute per install`), retryable: true }
  // Only the current minute is kept, so the table never grows past the active posters.
  const kept = Object.fromEntries(Object.entries(state.rate).filter(([, r]) => r.minute === minute))
  return { ok: true, rate: { ...kept, [scope]: { minute, count: used(scope) + 1 }, [base]: { minute, count: used(base) + 1 } } }
}

const tooBig = (item: FeedItem) => jsonBytes(item) > MAX_ITEM_BYTES

/** Inserts a new item after making room; refuses when the byte budget cannot hold it. */
const insert = (state: FeedState, item: FeedItem, rate: FeedState["rate"]): ReduceResult<FeedState> => {
  const room = evictForInsert(state)
  const openAfter = openRequestCount(room) + (item.type === "request" && item.state === "open" ? 1 : 0)
  if (!fitsBudget(room, jsonBytes(item), openAfter)) return { ...reject("feed.full", "the feed is full; archive or answer items first"), retryable: true }
  return {
    ok: true,
    state: { ...room, rate, next_order: state.next_order + 1, items: { ...room.items, [item.id]: item }, dedupe: claimDedupe(room.dedupe, item) },
    value: { item }
  }
}

/** feed.post: validate, rate-limit, dedupe, make room, insert (feed.md 3.5, section 4). */
export const reducePost = (state: FeedState, params: unknown, ctx: ReduceContext): ReduceResult<FeedState> => {
  const d = decodeParams<PostParams>(FeedPost, params)
  if (!d.ok) return d
  const v = d.value
  const bad = checkShape(v) ?? checkUrls(v.context, v.open)
  if (bad) return bad
  const p = ctx.principal
  const agent = p.agent ?? v.poster?.agent
  const scope = posterScope(p, agent)
  const counted = countPost(state, p, scope, ctx.now)
  if (!counted.ok) return counted
  const rate = counted.rate

  const existing = v.dedupe_key === undefined ? undefined : state.items[state.dedupe[`${scope}\u0000${v.dedupe_key}`] ?? ""]
  if (existing && isActive(existing)) {
    if (existing.type !== v.type || existing.kind !== v.kind) return reject("validation.invalid", `dedupe key ${v.dedupe_key} is held by an open ${existing.kind} item`, { item: existing.id })
    if (existing.type === "request") return { ok: true, state, value: { item: existing, deduped: true }, changed: false }
    const priority = v.priority ?? existing.priority
    const due = existing.push_due_at ?? (existing.pushed_at === null || ctx.now - existing.pushed_at >= REPUSH_AFTER_MS ? pushDueAt(state.prefs, priority, ctx.now) : null)
    const item = touch(existing, ctx.now, {
      title: v.title,
      body: v.body ?? "",
      priority,
      context: v.context ?? existing.context,
      attachments: v.attachments ?? existing.attachments,
      actions: v.actions ?? existing.actions,
      open: v.open ?? existing.open,
      count: existing.count + 1,
      read_at: null,
      seen_at: null,
      snoozed_until: null,
      expires_at: ctx.now + (v.expires_in_ms ?? DEFAULT_NOTICE_EXPIRY_MS),
      push_due_at: due
    })
    if (tooBig(item)) return reject("validation.invalid", `an item is at most ${MAX_ITEM_BYTES} bytes`)
    const next = { ...state, rate, items: { ...state.items, [item.id]: item } }
    if (!fitsBudget(next, 0, openRequestCount(next))) return { ...reject("feed.full", "the feed is full; archive or answer items first"), retryable: true }
    return { ok: true, state: next, value: { item, deduped: true } }
  }

  if (v.type === "request" && openRequestCount(state) >= MAX_OPEN_REQUESTS) {
    return { ...reject("feed.full", `at most ${MAX_OPEN_REQUESTS} open requests; answer or decline some first`), retryable: true }
  }
  const priority = v.priority ?? (v.type === "notice" ? "normal" : kindDefaultPriority(v.kind))
  const item: FeedItem = {
    id: ctx.newId("fi"),
    home: "cloud",
    type: v.type,
    kind: v.kind,
    title: v.title,
    body: v.body ?? "",
    ...(v.prompt === undefined ? {} : { prompt: v.prompt }),
    ...(v.answer_schema === undefined ? {} : { answer_schema: v.answer_schema }),
    priority,
    dedupe_key: v.dedupe_key ?? null,
    thread: v.thread ?? null,
    context: v.context ?? {},
    attachments: v.attachments ?? [],
    actions: v.actions ?? [],
    open: v.open ?? null,
    poster: {
      kind: posterKind(p, agent, v.poster?.kind),
      scope,
      label: v.poster?.label ?? "",
      ...(p.install ? { install: p.install } : {}),
      ...(agent ? { agent } : {}),
      ...(v.poster?.harness ? { harness: v.poster.harness } : {})
    },
    state: "open",
    answer: null,
    cancel: null,
    needs_mac: kindNeedsMac(v.kind),
    expires_at: ctx.now + (v.expires_in_ms ?? (v.type === "request" ? DEFAULT_REQUEST_EXPIRY_MS : DEFAULT_NOTICE_EXPIRY_MS)),
    read_at: null,
    seen_at: null,
    archived_at: null,
    snoozed_until: null,
    push_due_at: pushDueAt(state.prefs, priority, ctx.now),
    pushed_at: null,
    count: 1,
    order: state.next_order,
    revision: 1,
    created_at: ctx.now,
    updated_at: ctx.now,
    closed_at: null
  }
  if (tooBig(item)) return reject("validation.invalid", `an item is at most ${MAX_ITEM_BYTES} bytes`)
  const r = insert(state, item, rate)
  return r.ok ? { ...r, value: { item, deduped: false } } : r
}

/** Checks an item a local feed server hands over; returns the reason it is refused. */
const adoptProblem = (i: FeedItem, p: Principal): string | undefined => {
  if (i.poster.install !== p.install || !(i.poster.scope === `inst:${p.install}` || i.poster.scope.startsWith(`inst:${p.install}/agent:`))) return "the item's poster must be this install or its agents"
  const shape = checkShape({ type: i.type, kind: i.kind, prompt: i.prompt, answer_schema: i.answer_schema, actions: i.actions })
  if (shape) return shape.message
  if (checkUrls(i.context, i.open ?? undefined)) return "unsafe URL"
  const closed = i.state !== "open"
  if (closed !== (i.closed_at !== null)) return "closed_at does not match the state"
  if ((i.state === "answered") !== (i.answer !== null) || (i.state === "cancelled") !== (i.cancel !== null)) return "answer or cancel does not match the state"
  if (i.type === "notice" && i.state === "answered") return "a notice cannot be answered"
  if (i.answer !== null) {
    const r = checkAnswer(i.kind, i.prompt, i.answer_schema, i.answer.value)
    if (!r.ok) return `answer: ${r.message}`
  }
  if (i.type === "request" && i.state === "open" && (i.archived_at !== null || i.snoozed_until !== null)) return "an open request cannot be archived or snoozed"
  if (i.needs_mac !== kindNeedsMac(i.kind)) return "needs_mac does not match the kind"
  if (tooBig({ ...i, answer: null })) return `an item is at most ${MAX_ITEM_BYTES} bytes`
  return undefined
}

const MAX_SNOOZE_MS = 365 * 24 * 3600_000
const nullOrAtLeast = (t: number | null, min: number) => (t === null ? null : Math.max(t, min))

/**
 * The daemon's clock is not ours: times ahead of the DO clock come down to now and far deadlines to
 * the post limits. A refusal here would leave the local item in `handing_off` forever (feed.md 5.3e).
 */
const clampTimes = (i: FeedItem, now: number): FeedItem => {
  const past = (t: number) => Math.min(t, now)
  const pastOrNull = (t: number | null) => (t === null ? null : past(t))
  return {
    ...i,
    created_at: past(i.created_at),
    updated_at: past(i.updated_at),
    closed_at: pastOrNull(i.closed_at),
    read_at: pastOrNull(i.read_at),
    seen_at: pastOrNull(i.seen_at),
    archived_at: pastOrNull(i.archived_at),
    pushed_at: pastOrNull(i.pushed_at),
    answer: i.answer === null ? null : { ...i.answer, at: past(i.answer.at) },
    cancel: i.cancel === null ? null : { ...i.cancel, at: past(i.cancel.at) },
    expires_at: Math.min(i.expires_at, now + MAX_EXPIRY_MS),
    snoozed_until: i.snoozed_until === null ? null : Math.min(i.snoozed_until, now + MAX_SNOOZE_MS)
  }
}

/**
 * feed.adopt: a daemon's local feed server hands one of its own items to the
 * cloud (feed.md section 5). Same id; lifecycle and triage carry over after the
 * same checks a post and an answer get; a retry of the same id changes nothing.
 */
export const reduceAdopt = (state: FeedState, params: unknown, ctx: ReduceContext): ReduceResult<FeedState> => {
  const d = decodeParams<typeof FeedAdopt.params.Type>(FeedAdopt, params)
  if (!d.ok) return d
  const incoming = d.value.item
  const p = ctx.principal
  if (!p.install || incoming.home !== `local:${p.install}`) return reject("auth.forbidden", "a local feed server may hand over only items homed on its own install")
  const prior = state.items[incoming.id]
  if (prior) {
    if (prior.poster.install !== p.install) return reject("validation.invalid", "the id belongs to another item")
    return { ok: true, state, value: { item: prior }, changed: false }
  }
  const problem = adoptProblem(incoming, p)
  if (problem) return reject("validation.invalid", `cannot adopt: ${problem}`)
  const counted = countPost(state, p, incoming.poster.scope, ctx.now)
  if (!counted.ok) return counted
  if (incoming.type === "request" && incoming.state === "open" && openRequestCount(state) >= MAX_OPEN_REQUESTS) {
    return { ...reject("feed.full", "too many open requests to adopt more"), retryable: true }
  }
  const clamped = clampTimes(incoming, ctx.now)
  const item: FeedItem = {
    ...clamped,
    home: "cloud",
    poster: { ...incoming.poster, kind: posterKind(p, incoming.poster.agent, incoming.poster.kind) },
    // The user's cloud push preferences decide, never the daemon's value: the delay counts from the
    // item's creation, and an item already pushed, closed, read, seen or snoozed does not push.
    push_due_at: pushEligible(clamped) && clamped.pushed_at === null ? nullOrAtLeast(pushDueAt(state.prefs, clamped.priority, clamped.created_at), ctx.now) : null,
    order: state.next_order,
    revision: incoming.revision + 1,
    updated_at: ctx.now
  }
  return insert(state, item, counted.rate)
}
