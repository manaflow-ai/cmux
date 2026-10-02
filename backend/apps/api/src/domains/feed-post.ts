import type { Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import { checkAnswer, checkPrompt, FeedAdopt, FeedPost, kindDefaultPriority, kindNeedsMac, type FeedItem } from "@cmux/protocol"
import { decodeParams, reject } from "./common.ts"
import {
  claimDedupe,
  DEFAULT_NOTICE_EXPIRY_MS,
  DEFAULT_REQUEST_EXPIRY_MS,
  evictForInsert,
  isActive,
  MAX_OPEN_REQUESTS,
  MAX_POSTS_PER_MINUTE,
  openRequestCount,
  posterScope,
  pushDueAt,
  touch,
  type FeedState
} from "./feed-state.ts"

type PostParams = typeof FeedPost.params.Type
type PosterKind = FeedItem["poster"]["kind"]

/** The poster kind is declared, but a principal can only claim kinds that fit it. */
const posterKind = (p: Principal, agent: string | undefined, declared: PosterKind | undefined): PosterKind => {
  if (p.kind === "system") return declared === "integration" ? "integration" : "system"
  if (p.kind === "session") return "user"
  const allowed: ReadonlyArray<PosterKind> = agent ? ["agent", "harness", "app", "automation"] : ["agent", "server", "vm", "system"]
  if (declared && allowed.includes(declared)) {
    if (declared === "app" && !agent?.startsWith("app:")) return "agent"
    if (declared === "automation" && !agent?.startsWith("run_")) return "agent"
    return declared
  }
  return agent ? "agent" : "server"
}

const checkShape = (v: PostParams) => {
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

/** feed.post: validate, rate-limit, dedupe, make room, insert (feed.md 3.5, section 4). */
export const reducePost = (state: FeedState, params: unknown, ctx: ReduceContext): ReduceResult<FeedState> => {
  const d = decodeParams<PostParams>(FeedPost, params)
  if (!d.ok) return d
  const v = d.value
  const bad = checkShape(v)
  if (bad) return bad
  const p = ctx.principal
  const agent = p.agent ?? v.poster?.agent
  const scope = posterScope(p, agent)

  const minute = Math.floor(ctx.now / 60_000)
  const used = state.rate[scope]?.minute === minute ? state.rate[scope]!.count : 0
  if (used >= MAX_POSTS_PER_MINUTE) return { ...reject("feed.rate_limited", `at most ${MAX_POSTS_PER_MINUTE} posts per minute per poster`), retryable: true }
  // Only the current minute is kept, so the table never grows past the active posters.
  const rate = { ...Object.fromEntries(Object.entries(state.rate).filter(([, r]) => r.minute === minute)), [scope]: { minute, count: used + 1 } }

  const slot = v.dedupe_key === undefined ? undefined : `${scope}\u0000${v.dedupe_key}`
  const existing = slot === undefined ? undefined : state.items[state.dedupe[slot] ?? ""]
  if (existing && isActive(existing) && existing.type === v.type && existing.kind === v.kind) {
    if (existing.type === "request") return { ok: true, state, value: { item: existing, deduped: true }, changed: false }
    const priority = v.priority ?? existing.priority
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
      push_due_at: pushDueAt(state.prefs, priority, ctx.now),
      pushed_at: null
    })
    return { ok: true, state: { ...state, rate, items: { ...state.items, [item.id]: item } }, value: { item, deduped: true } }
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
  const room = evictForInsert(state)
  const next: FeedState = {
    ...room,
    rate,
    next_order: state.next_order + 1,
    items: { ...room.items, [item.id]: item },
    dedupe: claimDedupe(room.dedupe, item)
  }
  return { ok: true, state: next, value: { item, deduped: false } }
}

/**
 * feed.adopt: a daemon's local feed server hands one of its own items to the
 * cloud (feed.md section 5). Same id; the item keeps its lifecycle and triage
 * state; a retry or a second adopt of the same id changes nothing.
 */
export const reduceAdopt = (state: FeedState, params: unknown, ctx: ReduceContext): ReduceResult<FeedState> => {
  const d = decodeParams<typeof FeedAdopt.params.Type>(FeedAdopt, params)
  if (!d.ok) return d
  const incoming = d.value.item
  const p = ctx.principal
  if (!p.install || incoming.home !== `local:${p.install}`) return reject("auth.forbidden", "a local feed server may hand over only items homed on its own install")
  const prior = state.items[incoming.id]
  if (prior) return { ok: true, state, value: { item: prior }, changed: false }
  if (incoming.type === "request" && incoming.state === "open" && openRequestCount(state) >= MAX_OPEN_REQUESTS) {
    return { ...reject("feed.full", "too many open requests to adopt more"), retryable: true }
  }
  const item: FeedItem = { ...incoming, home: "cloud", order: state.next_order, revision: incoming.revision + 1, updated_at: ctx.now }
  const room = evictForInsert(state)
  return {
    ok: true,
    state: { ...room, next_order: state.next_order + 1, items: { ...room.items, [item.id]: item }, dedupe: claimDedupe(room.dedupe, item) },
    value: { item }
  }
}
