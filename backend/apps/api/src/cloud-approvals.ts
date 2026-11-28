import type { OwnerFrame, Principal, Reject, SqlStore } from "@cmux/ownership"
import { cloudOpByName } from "@cmux/protocol"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"
import type { DeliverResult, TargetItem } from "./do-outbox.ts"
import { decodeParams } from "./domains/common.ts"
import { CLOUD_APPROVAL_OPS, isAgent } from "./domains/cloud.ts"
import { approvalLedger, gateRiskyOp, isInFlight, postIntegrationApproval, runApproved, takeAnswer, withApprovalClass, withInFlight, type GateHost } from "./integrations/approval-gate.ts"
import { answerAdmitted } from "./integrations/approval-route.ts"
import { APPROVAL_RETENTION_MS, approvalByRequest, approvalView, backToPending, createApprovalTable, endApproval, expireDue, pruneApprovals, startRun, type ApprovalRow } from "./integrations/approvals.ts"
import type { ExternalReply } from "./integrations/external.ts"
import type { ReadResult } from "./owner-do.ts"

/**
 * G8 for Cloud (cx-wb5.65, chief decision 2026-10-08). Money and destructive Cloud ops are never
 * grantable to an install. When an install that is not an agent (the Mac relay) asks for one,
 * CloudDO keeps the exact request in its own approvals table (the integrations G8 machinery,
 * integrations/approvals.ts and approval-gate.ts), posts an approve request to the person's feed
 * (poster scope `system:cloud:<team>`) and answers `approval.pending {request, expires_at}`. The
 * person approves or denies with their own session (dashboard). An approval runs the op once,
 * under the install re-resolved from UserDO (a revoked install or a narrowed grant runs nothing),
 * with `approval` set on the principal only for that run, under the key `approval:<request>`.
 * A retry with the caller's key answers approval.pending, then the run's own answer (replayed),
 * or approval.denied / approval.expired.
 */
export const needsCloudApproval = (op: string, p: Principal) => CLOUD_APPROVAL_OPS.has(op) && p.kind === "install" && !isAgent(p) && p.approval === undefined

const TABLE = "integration_approvals"
/** Reads never create the table: an object nobody asked has none. */
const hasTable = (sql: SqlStorage) => sql.exec(`SELECT 1 AS one FROM sqlite_master WHERE type = 'table' AND name = ?`, TABLE).toArray().length > 0

export interface CloudApprovalHost {
  readonly env: Env
  readonly sql: SqlStorage
  readonly team: string
  readonly stream: string
  /** The domain's authorize for `p` (no ledger): a refusal, or undefined. */
  readonly authorize: (p: Principal, op: string, params: unknown) => Reject | undefined
  readonly armAlarm: () => void
}

/**
 * Principals this module made for an approved run. CloudCore.submitAs keeps `approval` only on these
 * objects: a principal that arrives by RPC is a new object, so it can never be one of them.
 */
const approvedRuns = new WeakSet<Principal>()
export const isApprovedRun = (p: Principal) => approvedRuns.has(p)

/** The principal of an approved run (or of a check): the risk class the approval stands in for, and the request it runs. */
export const approvedPrincipal = (p: Principal, risk: string, request: string): Principal => {
  const out: Principal = { ...withApprovalClass(p, risk), approval: request }
  approvedRuns.add(out)
  return out
}

/** What an approved run stores: its final frame, so a same-key retry gets what a direct call would have. */
interface CloudReply extends ExternalReply {
  readonly frame?: OwnerFrame
}

const settled = (key: string, stream: string, ok: boolean): OwnerFrame => ({ t: "request-settled", tx: "", idempotency_key: key, stream, sequence: 0, ok })
const refusal = (key: string, stream: string, code: string, message: string, retryable = false, details?: unknown): SubmitResult => ({
  frames: [{ t: "reject", tx: "", idempotency_key: key, code, message, ...(details === undefined ? {} : { details }), retryable, replayed: false }, settled(key, stream, false)]
})

const toReply = (op: string, key: string, stream: string, frames: ReadonlyArray<OwnerFrame>): CloudReply => {
  const base = { op, idempotency_key: key, replayed: false, stream, sequence: 0 }
  const f = frames.find((x) => x.t === "result" || x.t === "reject")
  if (f?.t === "result") return { ...base, ok: true, value: f.value, transaction: f.tx, frame: f }
  if (f?.t === "reject") return { ...base, ok: false, transaction: f.tx, error: { code: f.code, message: f.message, retryable: f.retryable, ...(f.details === undefined ? {} : { details: f.details }) }, frame: f }
  return { ...base, ok: false, transaction: "", error: { code: "owner.unreachable", message: "the approved request gave no answer", retryable: true } }
}

const replayFrames = (reply: unknown, key: string, stream: string): SubmitResult => {
  const f = (reply as CloudReply | null)?.frame
  if (!f || (f.t !== "result" && f.t !== "reject")) return refusal(key, stream, "mutation.indeterminate", "the approved request ended without a stored answer", false)
  return { frames: [{ ...f, idempotency_key: key, replayed: true }, settled(key, stream, f.t === "result")] }
}

const gateHost = (h: CloudApprovalHost): GateHost => ({
  sql: h.sql,
  // The authorize pre-check already ran; there is no provider connection to check.
  checkUsable: () => {},
  postApproval: (user, key, prompt, ms) => postIntegrationApproval(h.env, user, h.team, prompt, ms, key, "cloud"),
  armAlarm: h.armAlarm,
  // One flood-guard bucket per team (MAX_PENDING_PER_CONNECTION), plus MAX_PENDING_PER_IDENTITY per install.
  bucket: () => "cloud",
  // Chief decision: Cloud money and destructive requests from an install always ask; the integrations policy does not apply.
  action: () => "ask"
})

/** An install's request for a money or destructive op: pending, a stored answer (replayed), or a refusal. */
export const gateCloudRequest = async (h: CloudApprovalHost, principal: Principal, frame: { op: string; params: unknown; idempotency_key: string }): Promise<SubmitResult> => {
  const key = frame.idempotency_key
  const def = cloudOpByName.get(frame.op)
  if (!def) return refusal(key, h.stream, "validation.invalid", `unknown op ${frame.op}`)
  // Everything but the approval itself must already hold (team, membership, the rest of the grant).
  const denied = h.authorize(approvedPrincipal(principal, def.risk, "check"), frame.op, frame.params)
  if (denied) return refusal(key, h.stream, denied.code, denied.message, denied.retryable ?? false, denied.details)
  const d = decodeParams<Record<string, unknown>>(def, frame.params)
  if (!d.ok) return refusal(key, h.stream, d.code, d.message)
  createApprovalTable(h.sql)
  const g = await gateRiskyOp(gateHost(h), def, principal, d.value, principal.identity, key, Date.now())
  if (g.kind === "replay") return replayFrames(g.reply, key, h.stream)
  return refusal(key, h.stream, g.code, g.message, g.retryable ?? false, g.details)
}

/** How long a cut-off run waits between settle attempts (alarm), once past its expiry. */
const SETTLE_RETRY_MS = 60_000
/** The provider call of a committed intent is still running: the row stays running, never pending again. */
const committedButOpen = (r: ExternalReply) => !r.ok && r.error?.code === "mutation.indeterminate"

type Submit = (p: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }) => Promise<SubmitResult>

/**
 * One run of an approved request under `approval:<request>` (the install re-resolved and re-checked),
 * and its end: done with the op's answer, denied when the install may no longer run it, still running
 * while a committed intent's provider call is open (a retry with the same key replays and resumes it),
 * or back to pending for a retryable refusal before any commit. Throws when the outbox must redeliver.
 */
const execute = async (h: CloudApprovalHost, row: ApprovalRow, submit: Submit, audit: (e: Record<string, unknown>) => void): Promise<void> => {
  const allowed = (p: Principal, op: string, params: unknown) => !h.authorize(approvedPrincipal(p, "read", "check"), op, params)
  const run = async (p: Principal, r: ApprovalRow): Promise<ExternalReply> => {
    const principal = approvedPrincipal(p, cloudOpByName.get(r.op)!.risk, r.request)
    const { key } = approvalLedger(r)
    const reply = toReply(r.op, key, h.stream, (await submit(principal, { t: "op", op: r.op, params: r.params, idempotency_key: key, origin: "user" })).frames)
    audit({ op: "approval.run", request: r.request, approved_op: r.op, ok: reply.ok, code: reply.error?.code ?? null, by: principal.identity, user: principal.user ?? null, install: principal.install ?? null, approved_by: `session:${r.user}`, at: Date.now() })
    return reply
  }
  const reply = await withInFlight(h.sql, row.request, () => runApproved(h.env, allowed, run)(row))
  const now = Date.now()
  if (reply === "refused") return void endApproval(h.sql, row.request, "denied", now, null, ["running"])
  if (committedButOpen(reply)) throw new Error(`approved ${row.op} is still running`)
  if (!reply.ok && reply.error?.retryable) {
    backToPending(h.sql, row.request)
    throw new Error(`approved ${row.op} failed retryably`)
  }
  endApproval(h.sql, row.request, "done", now, reply, ["running"])
}

/**
 * The person's answers from their FeedDO (`integration.approval.answered`). An approval runs the
 * request once (execute); a redelivered answer for a run this instance is not awaiting (a restart cut
 * it off) runs the same key again, which replays the committed intent or runs it the first time.
 */
export const deliverCloudAnswers = async (h: CloudApprovalHost, source: string, items: ReadonlyArray<TargetItem>, submit: Submit, audit: (e: Record<string, unknown>) => void): Promise<DeliverResult> => {
  createApprovalTable(h.sql)
  const done: Array<number> = []
  for (const item of items) {
    const outcome = takeAnswer(h.sql, source, (item.params ?? {}) as Record<string, unknown>, Date.now())
    if (outcome.kind === "ignore") {
      if (outcome.reason !== "denied") console.warn(JSON.stringify({ msg: "cloud approval answer ignored", reason: outcome.reason }))
    } else if (outcome.kind === "settle") {
      await execute(h, outcome.row, submit, audit)
    } else if (!(await answerAdmitted(h.env, h.team, outcome.row.user, item.params))) {
      endApproval(h.sql, outcome.row.request, "denied", Date.now())
    } else if (startRun(h.sql, outcome.row.request)) {
      await execute(h, outcome.row, submit, audit)
    }
    done.push(item.id)
  }
  return { done }
}

/** integration.approval.get for a Cloud request: only the person's own session reads it. */
export const readCloudApproval = (sql: SqlStorage, principal: Principal, params: unknown): ReadResult =>
  hasTable(sql) ? approvalView(sql, principal, params, Date.now()) : { ok: false, code: "selector.not_found", message: "no such approval request" }

/** Running rows past their expiry that this instance is not awaiting: cut off, to settle. */
const stuck = (sql: SqlStorage, now: number) =>
  sql.exec<{ request: string }>(`SELECT request FROM integration_approvals WHERE state = 'running' AND expires_at <= ?`, now).toArray().map((r) => r.request).filter((r) => !isInFlight(sql, r))

/** The alarm time the approvals need: a pending expiry, a cut-off run to settle (once a minute), an ended row to prune. */
export const cloudApprovalsDueAt = (sql: SqlStorage, now: number): number | null => {
  if (!hasTable(sql)) return null
  const r = sql.exec<{ p: number | null; r: number | null; e: number | null }>(
    `SELECT (SELECT MIN(expires_at) FROM integration_approvals WHERE state = 'pending') AS p, (SELECT MIN(expires_at) FROM integration_approvals WHERE state = 'running') AS r, (SELECT MIN(ended_at) FROM integration_approvals WHERE ended_at IS NOT NULL) AS e`
  ).toArray()[0]
  const times = [r?.p ?? null, r?.r === null || r?.r === undefined ? null : Math.max(Number(r.r), now + SETTLE_RETRY_MS), r?.e === null || r?.e === undefined ? null : Number(r.e) + APPROVAL_RETENTION_MS].filter((t): t is number => t !== null)
  return times.length ? Math.min(...times) : null
}

/** Alarm: expire pending requests past their time, settle cut-off runs past it (never call twice: same key), prune ended rows. */
export const wakeCloudApprovals = async (h: CloudApprovalHost, now: number, submit: Submit, audit: (e: Record<string, unknown>) => void): Promise<void> => {
  if (!hasTable(h.sql)) return
  expireDue(h.sql, now)
  // At most one settle per wake: each can wait REQUEST_WAIT_MS, and the revoke drain and cost backstop run after.
  for (const request of stuck(h.sql, now).slice(0, 1)) {
    const row = approvalByRequest(h.sql, request)
    // Read again: a redelivery may have taken it meanwhile.
    if (!row || row.state !== "running" || isInFlight(h.sql, request)) continue
    try {
      await execute(h, row, submit, audit)
    } catch (e) {
      console.warn(JSON.stringify({ msg: "cloud approval settle pending", op: row.op, error: e instanceof Error ? e.message : "unknown" }))
    }
  }
  pruneApprovals(h.sql, now - APPROVAL_RETENTION_MS)
}

/** Starts per install and hour (chief decision, cx-wb5.65): a stolen install token cannot run up compute cost. */
export const INSTALL_START_LIMIT = 10
export const INSTALL_START_WINDOW_MS = 3_600_000

/** The per-install start ledger: only new intents count; created on the first install start. */
export class InstallStarts {
  private made = false
  constructor(private readonly sql: SqlStore) {}

  private table() {
    if (this.made) return
    this.sql.exec(`CREATE TABLE IF NOT EXISTS cloud_install_starts (install TEXT NOT NULL, at INTEGER NOT NULL)`)
    this.sql.exec(`CREATE INDEX IF NOT EXISTS cloud_install_starts_by ON cloud_install_starts (install, at)`)
    this.made = true
  }

  /**
   * Reserves a start for `install` (check and insert in one synchronous step, so parallel requests
   * cannot pass the limit together): the reservation id, or the time the oldest start in the window
   * leaves it when the install is at the limit.
   */
  reserve(install: string, now: number): { id: number } | { until: number } {
    this.table()
    this.sql.exec(`DELETE FROM cloud_install_starts WHERE at <= ?`, now - INSTALL_START_WINDOW_MS)
    const rows = this.sql.exec<{ at: number }>(`SELECT at FROM cloud_install_starts WHERE install = ? ORDER BY at`, install)
    if (rows.length >= INSTALL_START_LIMIT) return { until: rows[0]!.at + INSTALL_START_WINDOW_MS }
    this.sql.exec(`INSERT INTO cloud_install_starts (install, at) VALUES (?, ?)`, install, now)
    return { id: this.sql.exec<{ id: number }>(`SELECT last_insert_rowid() AS id`)[0]!.id }
  }

  /** Gives a reservation back: the start was refused, replayed or never committed. */
  release(id: number): void {
    this.sql.exec(`DELETE FROM cloud_install_starts WHERE rowid = ?`, id)
  }
}
