import { createHash } from "node:crypto"
import { canonicalJson, type Principal } from "@cmux/ownership"
import { cloudOpByName, type CloudOpDef } from "@cmux/protocol"
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
  endForMember,
  expireDue,
  insertApproval,
  MAX_PENDING_PER_CONNECTION,
  MAX_PENDING_PER_IDENTITY,
  pendingCount,
  pendingCountFor,
  backToPending,
  startRun,
  RISKY_CLASSES,
  setFeedItem,
  settleExpiry,
  type ApprovalRow
} from "./approvals.ts"
import type { ExternalReply } from "./external.ts"
import type { Env } from "../env.ts"
import { ProviderError } from "./providers.ts"
import { withGrantClasses } from "../auth.ts"
import type { ApprovalSource } from "../domains/feed-approvals.ts"

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
  readonly newRequestId?: () => string
  /** Arms the alarm for the new request's expiry. */
  readonly armAlarm: () => void
  /** What the per-bucket flood guard counts: the connection by default; CloudDO uses one bucket per team. */
  readonly bucket?: (params: Record<string, unknown>) => string
  /** Ask or block for this op: the integrations policy by default; CloudDO always asks (chief decision, cx-wb5.65). */
  readonly action?: (def: CloudOpDef) => "ask" | "block" | "allow"
}

/**
 * The caller's classes plus the op's risk class: the approval stands in for that one class.
 * A principal without resolved classes gets none (fail closed).
 */
export const withApprovalClass = (p: Principal, risk: string): Principal => (p.grant_classes ? { ...p, grant_classes: [...p.grant_classes, risk] } : p)

/**
 * The run of an approved request: the stored caller is resolved again (a session stays; an
 * install's grant is asked again, so a revoked install or a narrowed grant runs nothing) and
 * authorized again with the approval standing in for the risk class.
 */
export const runApproved =
  (env: Env, allowed: (p: Principal, op: string, params: unknown) => boolean, run: (p: Principal, row: ApprovalRow) => Promise<ExternalReply>) =>
  async (row: ApprovalRow): Promise<ExternalReply | "refused"> => {
    const now = await withGrantClasses(env, row.principal)
    const risk = cloudOpByName.get(row.op)?.risk
    if (!now || !risk || !allowed(withApprovalClass(now, risk), row.op, row.params)) return "refused"
    return run(now, row)
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
  if (row.state === "pending" || row.state === "running") return pendingAnswer(row)
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
  const action = host.action ? host.action(def) : resolveEffectivePolicy(def.name, [], defaultActionFor(def.risk as Parameters<typeof defaultActionFor>[0])).action
  if (action === "block") return { kind: "refuse", code: "policy.denied", message: `${def.name} is blocked for agents, automations and apps` }
  const paramsHash = approvalDigest(def.name, params)
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
  const connection = host.bucket ? host.bucket(params) : String(params.connection)
  if (pendingCount(host.sql, connection, now) >= MAX_PENDING_PER_CONNECTION || pendingCountFor(host.sql, identity, now) >= MAX_PENDING_PER_IDENTITY) {
    return { kind: "refuse", code: "approval.too_many_pending", message: `too many requests wait for approval (at most ${MAX_PENDING_PER_IDENTITY} per caller and ${MAX_PENDING_PER_CONNECTION} per connection)`, retryable: true }
  }
  const request = host.newRequestId?.() ?? `apr_${crypto.randomUUID().replace(/-/g, "")}`
  const digest = approvalDigest(def.name, params)
  const { target, summary } = describeRequest(def.name, params)
  insertApproval(host.sql, { request, identity, idempotency_key: key, user: principal.user, connection, op: def.name, params, params_hash: paramsHash, digest, principal, target, summary, created_at: now, expires_at: now + APPROVAL_TTL_MS })
  const prompt = {
    action: {
      type: "tool",
      tool: def.name,
      summary: `${def.name} ${host.bucket ? "for" : "to"} ${target || "this connection"}${summary ? `: ${summary}` : ""}`.slice(0, 500),
      risk: def.risk,
      input: { approval: { team: principal.team ?? "", request, digest }, connection, target, summary }
    },
    scopes: ["once"]
  }
  host.armAlarm()
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
export type AnswerOutcome = { readonly kind: "ignore"; readonly reason: string } | { readonly kind: "run" | "settle"; readonly row: ApprovalRow }

/** Requests whose provider call is awaiting in this object instance (lost on eviction, which is the point). */
const running = new WeakMap<SqlStorage, Set<string>>()
const inFlight = (sql: SqlStorage) => running.get(sql) ?? running.set(sql, new Set()).get(sql)!

/** The derived ledger key of an approved run. */
export const approvalLedger = (row: ApprovalRow) => ({ identity: `${row.identity}#approval`, key: `approval:${row.request}` })

/**
 * Ends a `running` request whose call was cut off: the ledger's stored reply if the call finished,
 * else `mutation.indeterminate` (the provider may have acted; never call it again).
 */
export const settleRunning = (sql: SqlStorage, row: ApprovalRow, now: number) => {
  const { identity, key } = approvalLedger(row)
  const ledger = sql.exec<{ status: string; reply: string | null }>(`SELECT status, reply FROM external_calls WHERE identity = ? AND idempotency_key = ?`, identity, key).toArray()[0]
  const reply = ledger?.status === "done" && ledger.reply
    ? (JSON.parse(ledger.reply) as unknown)
    : { ok: false, op: row.op, error: { code: "mutation.indeterminate", message: "the approved call was interrupted; check the provider before asking again", retryable: false }, transaction: "", idempotency_key: key, replayed: false, stream: "", sequence: 0 }
  endApproval(sql, row.request, "done", now, reply, ["running"])
}

/** Alarm: pending requests past their time expire; running ones past it that are not in flight settle from the ledger. */
export const expireApprovals = (sql: SqlStorage, now: number) => {
  expireDue(sql, now)
  const stuck = sql.exec<{ request: string }>(`SELECT request FROM integration_approvals WHERE state = 'running' AND expires_at <= ?`, now).toArray()
  for (const { request } of stuck) {
    const row = approvalByRequest(sql, request)
    if (row && !inFlight(sql).has(request)) settleRunning(sql, row, now)
  }
}

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
  // A run cut off by a restart (not in flight in this instance) is settled from the ledger, never run again.
  if (current.state === "running" && !inFlight(sql).has(row.request)) return { kind: "settle", row }
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
export const deliverAnswers = async (
  sql: SqlStorage,
  source: string,
  items: ReadonlyArray<{ readonly id: number; readonly op?: string; readonly params: unknown }>,
  run: (row: ApprovalRow) => Promise<ExternalReply | "refused">,
  /** Answer-time checks (membership, team SSO; approval-route.ts answerAdmitted); false ends it denied and runs nothing. */
  admit?: (row: ApprovalRow, params: unknown) => Promise<boolean>,
  /** This ConnectionDO's team: a member_left counts only from that team's own TeamDO stream. */
  team?: string
): Promise<Array<number>> => {
  const done: Array<number> = []
  for (const item of items) {
    if (item.op === "connections.member_left") {
      const v = (item.params ?? {}) as { team?: unknown; user?: unknown; at?: unknown }
      if (team !== undefined && v.team === team && source === `team:${team}` && typeof v.user === "string") endForMember(sql, v.user, typeof v.at === "number" ? v.at : Date.now(), Date.now())
      else console.warn(JSON.stringify({ msg: "member_left ignored", source }))
      done.push(item.id)
      continue
    }
    const outcome = takeAnswer(sql, source, (item.params ?? {}) as Record<string, unknown>, Date.now())
    if (outcome.kind === "settle") settleRunning(sql, outcome.row, Date.now())
    else if (outcome.kind === "run" && admit && !(await admit(outcome.row, item.params))) endApproval(sql, outcome.row.request, "denied", Date.now())
    else if (outcome.kind === "run" && startRun(sql, outcome.row.request)) {
      let reply: ExternalReply | "refused"
      inFlight(sql).add(outcome.row.request)
      try {
        reply = await run(outcome.row)
      } catch (e) {
        backToPending(sql, outcome.row.request)
        throw e
      } finally {
        inFlight(sql).delete(outcome.row.request)
      }
      // The caller is no longer allowed (install revoked, grant narrowed): final, nothing ran.
      if (reply === "refused") endApproval(sql, outcome.row.request, "denied", Date.now(), null, ["running"])
      else if (!reply.ok && reply.error?.retryable) {
        backToPending(sql, outcome.row.request)
        throw new Error(`approved ${outcome.row.op} failed retryably`)
      } else endApproval(sql, outcome.row.request, "done", Date.now(), reply, ["running"])
    } else if (outcome.kind === "ignore" && outcome.reason !== "denied") {
      console.warn(JSON.stringify({ msg: "approval answer ignored", reason: outcome.reason }))
    }
    done.push(item.id)
  }
  return done
}

/** Outbox items the ConnectionDO handles itself (DO-local approvals table), not through its engine. */
export const APPROVAL_ITEM_OPS: ReadonlySet<string> = new Set(["integration.approval.answered", "connections.member_left"])

/**
 * The FeedDO RPC that posts an approve request to `user`'s feed (G8); returns the item id. `source`
 * names the posting owner of `team`: its ConnectionDO (integrations) or its CloudDO (cx-wb5.65).
 */
export const postIntegrationApproval = async (env: Env, user: string, team: string, prompt: unknown, expiresInMs: number, key: string, source: ApprovalSource = "connections"): Promise<string> => {
  const feed = env.FEED_DO.get(env.FEED_DO.idFromName(user)) as unknown as {
    integrationApproval(user: string, team: string, prompt: unknown, expiresInMs: number, key: string, source: ApprovalSource): Promise<{ ok: true; item: string } | { ok: false; message: string }>
  }
  const r = await feed.integrationApproval(user, team, prompt, expiresInMs, key, source)
  if (!r.ok) throw new Error(r.message)
  return r.item
}
