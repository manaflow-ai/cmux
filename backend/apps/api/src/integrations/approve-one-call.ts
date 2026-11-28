import type { Principal } from "@cmux/ownership"
import type { Env } from "../env.ts"
import type { SubmitResult } from "../owner-do.ts"
import { platformCloud } from "../platform-cloud.ts"
import { answerPrincipal, approvalRoute } from "./approval-route.ts"

/**
 * `integration.approval.approve` (G8 in one call, behind CLOUD_APPROVE_ONE_CALL). The Mac answered a Cloud create's
 * approval in three sequential session calls after `approval.pending` (integration.approval.get, feed.list, feed.answer)
 * and then retried the create with the same key to get the machine: five round trips at 0.26-0.98 s each. This op does
 * the same checks here, answers the same item, and carries the approved run's reply, so pending plus this is two.
 *
 * The checks and their order are the Mac's (CloudApprovalAnswer.swift): the approval reads `op`, pending, exactly
 * `params` (deep JSON equality) and a digest; then the person's open approve item for the request, with that digest and
 * op, of `team`, posted by `system:cloud:<team>`, is answered allow once. No open one, but that team's closed one: it was
 * answered elsewhere (nothing is answered here). Any mismatch refuses `approval.mismatch` with the Mac's reason and
 * answers nothing. No authorization changes: the caller is the person's own session (op principals), the read and the
 * answer go as that session exactly as the Mac's calls do (approvalRoute's reader, answerPrincipal's SSO), and CloudDO
 * still re-checks the answer before the run (answerAdmitted).
 *
 * The run's wait is bounded by one budget from the start of the call (APPROVE_ONE_CALL_BUDGET_MS, under the Mac's 15 s
 * request timeout and never longer than feed.answer's 2 s plus the same-key retry's 10 s it replaces). A run still going
 * after it, or a CloudDO that cannot answer, leaves `reply` out: the caller retries the create with the same key as before.
 */
export const APPROVE_ONE_CALL_BUDGET_MS = 10_000

/** The reasons the Mac's checks name (CloudApprovalAnswer.Failure.mismatch); `feed item or team` is its closedItem. */
export type MismatchReason = "op" | "state" | "params" | "digest" | "feed item or team"

export type ItemLookup = { readonly open: string } | { readonly closed: true } | null

export interface ApproveDeps {
  /** approvalRoute: the reader and owner of `request` for this session. */
  readonly route: (p: Principal, request: string) => Promise<{ reader: Principal; owner: string }>
  /** integration.approval.get as `reader` at `owner` (CloudDO readOp). */
  readonly read: (reader: Principal, owner: string, request: string) => Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
  /** FeedDO cloudApprovalItem: the person's open item for exactly this approval, or that team's closed one. */
  readonly item: (user: string, a: { request: string; op: string; digest: string; team: string }) => Promise<ItemLookup>
  /** feed.answer {item, allow once} as the person's session (answerPrincipal), origin user, under `key`. */
  readonly answer: (p: Principal, item: string, key: string) => Promise<{ ok: true } | { ok: false; code: string; message: string; retryable: boolean }>
  /** CloudDO approvalRun as `reader`: the run's state and reply, waited for at most `waitMs`. May throw (an older platform). */
  readonly run: (reader: Principal, request: string, waitMs: number) => Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>
  readonly now: () => number
}

export interface ApproveParams {
  readonly request: string
  readonly op: string
  readonly params: unknown
  readonly team: string
}

export type ApproveOutcome =
  | { readonly ok: true; readonly value: { request: string; answered: "here" | "elsewhere"; state?: string; reply?: unknown } }
  | { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean; readonly details?: unknown }

const mismatch = (reason: MismatchReason): ApproveOutcome => ({ ok: false, code: "approval.mismatch", message: `the request differs from the one confirmed: ${reason}`, retryable: false, details: { reason } })

/** Deep JSON equality, key order ignored (the Mac's NSDictionary isEqual of decoded JSON). */
export const sameJson = (a: unknown, b: unknown): boolean => {
  if (a === b) return true
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return false
  if (Array.isArray(a) !== Array.isArray(b)) return false
  if (Array.isArray(a)) return a.length === (b as Array<unknown>).length && a.every((x, i) => sameJson(x, (b as Array<unknown>)[i]))
  const ak = Object.keys(a as object)
  const bk = Object.keys(b as object)
  return ak.length === bk.length && ak.every((k) => Object.hasOwn(b as object, k) && sameJson((a as Record<string, unknown>)[k], (b as Record<string, unknown>)[k]))
}

export const approveInOneCall = async (deps: ApproveDeps, principal: Principal, p: ApproveParams, key: string): Promise<ApproveOutcome> => {
  const started = deps.now()
  if (principal.kind !== "session" || !principal.user) return { ok: false, code: "auth.forbidden", message: "only the person's own session approves", retryable: false }
  const { reader, owner } = await deps.route(principal, p.request)
  // Only a Cloud request (CloudDO's) is approved here; an integrations request keeps the feed's own answer.
  if (owner !== "cloud:CloudDO") return { ok: false, code: "selector.not_found", message: "no such Cloud approval request", retryable: false }
  const read = await deps.read(reader, owner, p.request)
  if (!read.ok) return { ok: false, code: read.code, message: read.message, retryable: false }
  const held = (read.value ?? {}) as Record<string, unknown>
  if (held.op !== p.op) return mismatch("op")
  if (held.state !== "pending") return mismatch("state")
  if (typeof p.params !== "object" || p.params === null || Array.isArray(p.params) || !sameJson(held.params, p.params)) return mismatch("params")
  if (typeof held.digest !== "string") return mismatch("digest")
  const found = await deps.item(principal.user, { request: p.request, op: p.op, digest: held.digest, team: p.team })
  if (!found) return mismatch("feed item or team")
  let answered: "here" | "elsewhere" = "elsewhere"
  if ("open" in found) {
    const a = await deps.answer(principal, found.open, key)
    if (!a.ok) return { ok: false, code: a.code, message: a.message, retryable: a.retryable }
    answered = "here"
  }
  const waitMs = Math.max(0, APPROVE_ONE_CALL_BUDGET_MS - (deps.now() - started))
  const run = await deps.run(reader, p.request, waitMs).catch(() => null)
  const v = run?.ok ? ((run.value ?? {}) as { state?: unknown; reply?: unknown }) : {}
  return {
    ok: true,
    value: {
      request: p.request,
      answered,
      ...(typeof v.state === "string" ? { state: v.state } : {}),
      ...(v.reply !== undefined ? { reply: v.reply } : {})
    }
  }
}

/**
 * The Worker's deps over this deployment's objects. `resolved` is the caller as the read path resolves it for
 * integration.approval.get (principalFor its catalog owner); `answerAs` is the caller as the mutate path answers
 * feed.answer (answerPrincipal, with the item's team SSO session when it is another team's).
 */
export const liveApproveDeps = (env: Env, resolved: Principal): ApproveDeps => ({
  route: (_p, request) => approvalRoute(env, resolved, { request }),
  read: (reader, _owner, request) => platformCloud(env.CLOUD_DO, reader.team!).readOp(reader.team!, reader, "integration.approval.get", { request }) as Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>,
  item: (user, a) => env.FEED_DO.get(env.FEED_DO.idFromName(user)).cloudApprovalItem(user, a),
  answer: async (p, item, key) => {
    const params = { item, answer: { decision: "allow", scope: "once" } }
    const as = await answerPrincipal(env, p, "feed.answer", params)
    const res = (await env.FEED_DO.get(env.FEED_DO.idFromName(p.user!)).submit(p.user!, as, { t: "op", op: "feed.answer", params, idempotency_key: key, origin: "user" })) as SubmitResult
    const f = res.frames.find((x) => x.t === "result" || x.t === "reject")
    if (f?.t === "result") return { ok: true }
    if (f?.t === "reject") return { ok: false, code: f.code, message: f.message, retryable: f.retryable }
    return { ok: false, code: "owner.unreachable", message: "the feed gave no answer", retryable: true }
  },
  run: (reader, request, waitMs) => platformCloud(env.CLOUD_DO, reader.team!).approvalRun(reader.team!, reader, request, waitMs) as Promise<{ ok: true; value: unknown } | { ok: false; code: string; message: string }>,
  now: () => Date.now()
})
