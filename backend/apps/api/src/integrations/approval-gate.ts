import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import type { CloudOpDef } from "@cmux/protocol"
// The shared per-tool policy (integrations-core): risky classes default to ask (send-external)
// or block (money, destructive); only a rule for the exact tool loosens a block.
import { defaultActionFor, resolveEffectivePolicy } from "../../../../../libs/integrations-core/src/policy.ts"
import {
  APPROVAL_TTL_MS,
  approvalByKey,
  approvalByRequest,
  deleteApproval,
  describeRequest,
  endApproval,
  insertApproval,
  MAX_PENDING_PER_CONNECTION,
  pendingCount,
  RISKY_CLASSES,
  setFeedItem,
  settleExpiry,
  type ApprovalRow
} from "./approvals.ts"
import type { ExternalReply } from "./external.ts"
import type { Env } from "../env.ts"
import { ProviderError } from "./providers.ts"

/** A gate answer: a final refusal or pending state for the caller, or a replay of the approved run. */
export type GateAnswer =
  | { readonly kind: "refuse"; readonly code: string; readonly message: string; readonly retryable?: boolean; readonly details?: unknown }
  | { readonly kind: "replay"; readonly reply: unknown }

export interface GateHost {
  readonly sql: SqlStorage
  /** Throws a ProviderError when the connection is not usable for this principal and op (same checks as a run). */
  readonly checkUsable: (principal: Principal, op: string, params: Record<string, unknown>) => void
  /** Posts the approve request to the user's feed; returns the feed item id. */
  readonly postApproval: (user: string, key: string, prompt: unknown, expiresInMs: number) => Promise<string>
  readonly newRequestId: () => string
}

/** sha256 of the canonical op and params: the exact request the person approves. */
export const approvalDigest = (op: string, params: Record<string, unknown>) => `sha256:${createHash("sha256").update(canonicalJson({ op, params })).digest("hex")}`

/**
 * True when this op needs the person's approval for this principal: a send-external, money or
 * destructive op from anyone but the person's own session. The policy decides between ask
 * (approval) and block (refused); with no rules the class default applies.
 */
export const needsApproval = (def: CloudOpDef, principal: Principal): boolean => RISKY_CLASSES.has(def.risk) && principal.kind !== "session"

const pendingAnswer = (row: ApprovalRow): GateAnswer => ({
  kind: "refuse",
  code: "approval.pending",
  message: `${row.op} waits for the user's approval in the feed`,
  retryable: true,
  details: { request: row.request, expires_at: row.expires_at }
})

const stateAnswer = (row: ApprovalRow): GateAnswer => {
  if (row.state === "pending") return pendingAnswer(row)
  if (row.state === "done") return { kind: "replay", reply: row.reply }
  if (row.state === "denied") return { kind: "refuse", code: "approval.denied", message: "the user denied this request", details: { request: row.request } }
  return { kind: "refuse", code: "approval.expired", message: "the approval request expired; ask again with a new key", details: { request: row.request } }
}

/**
 * The gate for one call (G8). `identity`/`key` are the caller's ledger identity and idempotency
 * key: a retry with the same key reads the same request (pending, denied, expired, or the stored
 * result), and never posts a second feed request.
 */
export const gateRiskyOp = async (host: GateHost, def: CloudOpDef, principal: Principal, params: Record<string, unknown>, identity: string, key: string, now: number): Promise<GateAnswer> => {
  const action = resolveEffectivePolicy(def.name, [], defaultActionFor(def.risk as Parameters<typeof defaultActionFor>[0])).action
  if (action === "block") return { kind: "refuse", code: "policy.denied", message: `${def.name} is blocked for agents, automations and apps` }
  const paramsHash = canonicalJson({ op: def.name, params })
  const prior = approvalByKey(host.sql, identity, key)
  if (prior) {
    if (prior.params_hash !== paramsHash) return { kind: "refuse", code: "idempotency.conflict", message: "idempotency key reused with different params" }
    return stateAnswer(settleExpiry(host.sql, prior, now))
  }
  if (!principal.user) return { kind: "refuse", code: "auth.forbidden", message: "an approval needs a user to ask" }
  try {
    host.checkUsable(principal, def.name, params)
  } catch (e) {
    if (e instanceof ProviderError) return { kind: "refuse", code: e.code === "needs_reauth" ? "integration.unavailable" : e.code, message: e.message }
    throw e
  }
  const connection = String(params.connection)
  if (pendingCount(host.sql, connection, now) >= MAX_PENDING_PER_CONNECTION) {
    return { kind: "refuse", code: "approval.too_many_pending", message: `at most ${MAX_PENDING_PER_CONNECTION} requests may wait for approval on one connection`, retryable: true }
  }
  const request = host.newRequestId()
  const digest = approvalDigest(def.name, params)
  const { target, summary } = describeRequest(def.name, params)
  insertApproval(host.sql, { request, identity, idempotency_key: key, user: principal.user, connection, op: def.name, params, params_hash: paramsHash, digest, principal, created_at: now, expires_at: now + APPROVAL_TTL_MS })
  const prompt = {
    action: {
      type: "tool",
      tool: def.name,
      summary: `${def.name} to ${target || "this connection"}${summary ? `: ${summary}` : ""}`.slice(0, 500),
      risk: def.risk,
      input: { approval: { team: principal.team ?? "", request, digest }, connection, target, summary }
    },
    scopes: ["once"]
  }
  try {
    setFeedItem(host.sql, request, await host.postApproval(principal.user, `approval:${request}`, prompt, APPROVAL_TTL_MS))
  } catch (e) {
    deleteApproval(host.sql, request)
    console.error(JSON.stringify({ msg: "approval post failed", op: def.name, error: e instanceof Error ? e.name : "unknown" }))
    return { kind: "refuse", code: "owner.unreachable", message: "could not ask for approval; try again", retryable: true }
  }
  return pendingAnswer(approvalByRequest(host.sql, request)!)
}

/** What the answer delivery decides for one request. */
export type AnswerOutcome = { readonly kind: "ignore"; readonly reason: string } | { readonly kind: "run"; readonly row: ApprovalRow }

/**
 * An answer from the user's FeedDO (outbox item `integration.approval.answered`). Only that
 * user's feed answers; a digest that is not the stored request's is refused (the request stays
 * pending); a deny is final. Anything not pending is ignored, so redelivery never runs twice.
 */
export const takeAnswer = (sql: SqlStorage, source: string, params: { request?: unknown; decision?: unknown; digest?: unknown }, now: number): AnswerOutcome => {
  const row = typeof params.request === "string" ? approvalByRequest(sql, params.request) : undefined
  if (!row) return { kind: "ignore", reason: "unknown request" }
  if (source !== `feed:${row.user}`) return { kind: "ignore", reason: "not the requesting user's feed" }
  const current = settleExpiry(sql, row, now)
  if (current.state !== "pending") return { kind: "ignore", reason: `request is ${current.state}` }
  if (params.decision !== "allow") {
    endApproval(sql, row.request, "denied", now)
    return { kind: "ignore", reason: "denied" }
  }
  if (params.digest !== row.digest || approvalDigest(row.op, row.params) !== row.digest) return { kind: "ignore", reason: "digest mismatch" }
  return { kind: "run", row }
}

/**
 * Runs the answers one FeedDO delivered (outbox items `integration.approval.answered`): an
 * approved request runs once through `run` (the ledgered provider call under the derived key).
 * A retryable failure throws, so the outbox redelivers and the request stays pending. Returns the
 * delivered item ids.
 */
export const deliverAnswers = async (sql: SqlStorage, source: string, items: ReadonlyArray<{ readonly id: number; readonly params: unknown }>, run: (row: ApprovalRow) => Promise<ExternalReply>): Promise<Array<number>> => {
  const done: Array<number> = []
  for (const item of items) {
    const outcome = takeAnswer(sql, source, (item.params ?? {}) as Record<string, unknown>, Date.now())
    if (outcome.kind === "run") {
      const reply = await run(outcome.row)
      if (!reply.ok && reply.error?.retryable) throw new Error(`approved ${outcome.row.op} failed retryably`)
      endApproval(sql, outcome.row.request, "done", Date.now(), reply)
    } else if (outcome.reason !== "denied") {
      console.warn(JSON.stringify({ msg: "approval answer ignored", reason: outcome.reason }))
    }
    done.push(item.id)
  }
  return done
}

/** The FeedDO RPC that posts an integration approve request to `user`'s feed (G8); returns the item id. */
export const postIntegrationApproval = async (env: Env, user: string, team: string, prompt: unknown, expiresInMs: number, key: string): Promise<string> => {
  const feed = env.FEED_DO.get(env.FEED_DO.idFromName(user)) as unknown as {
    integrationApproval(user: string, team: string, prompt: unknown, expiresInMs: number, key: string): Promise<{ ok: true; item: string } | { ok: false; message: string }>
  }
  const r = await feed.integrationApproval(user, team, prompt, expiresInMs, key)
  if (!r.ok) throw new Error(r.message)
  return r.item
}
