import type { OwnerFrame, Principal, Reject, SqlStore } from "@cmux/ownership"
import { cloudOpByName } from "@cmux/protocol"
import type { Env } from "./env.ts"
import type { SubmitResult } from "./owner-do.ts"
import type { DeliverResult, TargetItem } from "./do-outbox.ts"
import { decodeParams } from "./domains/common.ts"
import { CLOUD_APPROVAL_OPS, isAgent } from "./domains/cloud.ts"
import { approvalLedger, deliverAnswers, expireApprovals, gateRiskyOp, postIntegrationApproval, runApproved, withApprovalClass, type GateHost } from "./integrations/approval-gate.ts"
import { answerAdmitted } from "./integrations/approval-route.ts"
import { APPROVAL_RETENTION_MS, approvalView, createApprovalTable, nextApprovalAt, pruneApprovals, type ApprovalRow } from "./integrations/approvals.ts"
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

/** The principal of an approved run: the risk class the approval stands in for, and the request it runs. */
export const approvedPrincipal = (p: Principal, risk: string, request: string): Principal => ({ ...withApprovalClass(p, risk), approval: request })

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

/**
 * The person's answers from their FeedDO (`integration.approval.answered`): an approved request
 * runs once through `submit` under the derived key; the access audit names the install and the request.
 */
export const deliverCloudAnswers = async (
  h: CloudApprovalHost,
  source: string,
  items: ReadonlyArray<TargetItem>,
  submit: (p: Principal, frame: { t: "op"; op: string; params: unknown; idempotency_key: string; origin: "user" }) => Promise<SubmitResult>,
  audit: (entry: Record<string, unknown>) => void
): Promise<DeliverResult> => {
  createApprovalTable(h.sql)
  const allowed = (p: Principal, op: string, params: unknown) => !h.authorize({ ...p, approval: "check" }, op, params)
  const run = async (p: Principal, row: ApprovalRow): Promise<ExternalReply> => {
    const principal = approvedPrincipal(p, cloudOpByName.get(row.op)!.risk, row.request)
    const { key } = approvalLedger(row)
    audit({ op: "approval.run", request: row.request, approved_op: row.op, by: principal.identity, user: principal.user ?? null, install: principal.install ?? null, at: Date.now() })
    return toReply(row.op, key, h.stream, (await submit(principal, { t: "op", op: row.op, params: row.params, idempotency_key: key, origin: "user" })).frames)
  }
  const done = await deliverAnswers(h.sql, source, items, runApproved(h.env, allowed, run), (row, params) => answerAdmitted(h.env, h.team, row.user, params), h.team)
  return { done }
}

/** integration.approval.get for a Cloud request: only the person's own session reads it. */
export const readCloudApproval = (sql: SqlStorage, principal: Principal, params: unknown): ReadResult =>
  hasTable(sql) ? approvalView(sql, principal, params, Date.now()) : { ok: false, code: "selector.not_found", message: "no such approval request" }

/** The alarm time the approvals need (expiry of a pending request, pruning of an ended one), or null. */
export const cloudApprovalsDueAt = (sql: SqlStorage): number | null => (hasTable(sql) ? nextApprovalAt(sql) : null)

/** Alarm: expire pending requests past their time, settle cut-off runs, prune ended rows after 30 days. */
export const wakeCloudApprovals = (sql: SqlStorage, now: number) => {
  if (!hasTable(sql)) return
  expireApprovals(sql, now)
  pruneApprovals(sql, now - APPROVAL_RETENTION_MS)
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

  /** The time the oldest start in the window leaves it, when this install is at the limit; else null. */
  limitedUntil(install: string, now: number): number | null {
    this.table()
    this.sql.exec(`DELETE FROM cloud_install_starts WHERE at <= ?`, now - INSTALL_START_WINDOW_MS)
    const rows = this.sql.exec<{ at: number }>(`SELECT at FROM cloud_install_starts WHERE install = ? ORDER BY at`, install)
    return rows.length >= INSTALL_START_LIMIT ? rows[0]!.at + INSTALL_START_WINDOW_MS : null
  }

  record(install: string, now: number): void {
    this.table()
    this.sql.exec(`INSERT INTO cloud_install_starts (install, at) VALUES (?, ?)`, install, now)
  }
}
