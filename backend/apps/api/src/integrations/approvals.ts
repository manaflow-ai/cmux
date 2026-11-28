import type { Principal } from "@cmux/ownership"

/**
 * G8 gateway approvals (plans/cmux-next/integrations-plan.md section 3). A provider op with risk
 * send-external, money or destructive from a principal that is not the person's own session does
 * not run: the ConnectionDO keeps the exact request here, posts an `approve` feed request to the
 * acting user, and answers `approval.pending {request}`. The user's answer (delivered by that
 * user's FeedDO) runs it once under the key `approval:<request>` in the external-call ledger.
 *
 * The params (a mail body, a message) stay in this DO-local table: never in the replicated
 * state, events, the feed item or the projection. The feed item shows the op, the target and a
 * short summary; the approval view reads the rest with the user's session
 * (`integration.approval.get`). Rows leave 30 days after they end.
 *
 * CloudDO keeps the same table for Cloud money and destructive requests from an install
 * (cloud-approvals.ts, cx-wb5.65); its rows name the bucket `cloud` instead of a connection.
 */
export const RISKY_CLASSES: ReadonlySet<string> = new Set(["send-external", "money", "destructive"])
export const APPROVAL_TTL_MS = 24 * 3_600_000
export const MAX_PENDING_PER_CONNECTION = 20
/** One caller (an agent, an app) may hold at most this many of them, so it cannot crowd out others. */
export const MAX_PENDING_PER_IDENTITY = 5
export const APPROVAL_RETENTION_MS = 30 * 24 * 3_600_000

export type ApprovalState = "pending" | "running" | "done" | "denied" | "expired"

export interface ApprovalRow {
  readonly request: string
  readonly identity: string
  readonly idempotency_key: string
  readonly user: string
  readonly connection: string
  readonly op: string
  readonly params: Record<string, unknown>
  readonly params_hash: string
  readonly digest: string
  readonly principal: Principal
  readonly feed_item: string | null
  readonly state: ApprovalState
  readonly reply: unknown
  readonly target: string
  readonly summary: string
  readonly created_at: number
  readonly expires_at: number
  readonly ended_at: number | null
}

type Sql = SqlStorage

export const createApprovalTable = (sql: Sql) => {
  sql.exec(`CREATE TABLE IF NOT EXISTS integration_approvals (
    request TEXT PRIMARY KEY, identity TEXT NOT NULL, idempotency_key TEXT NOT NULL, user TEXT NOT NULL,
    connection TEXT NOT NULL, op TEXT NOT NULL, params TEXT NOT NULL, params_hash TEXT NOT NULL, digest TEXT NOT NULL,
    principal TEXT NOT NULL, feed_item TEXT, state TEXT NOT NULL, reply TEXT, target TEXT NOT NULL DEFAULT '', summary TEXT NOT NULL DEFAULT '', created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL, ended_at INTEGER, UNIQUE (identity, idempotency_key))`)
  sql.exec(`CREATE INDEX IF NOT EXISTS integration_approvals_pending ON integration_approvals (connection, state)`)
}

type Raw = Record<string, SqlStorageValue>
const decode = (r: Raw): ApprovalRow => ({
  request: String(r.request),
  identity: String(r.identity),
  idempotency_key: String(r.idempotency_key),
  user: String(r.user),
  connection: String(r.connection),
  op: String(r.op),
  params: JSON.parse(String(r.params)) as Record<string, unknown>,
  params_hash: String(r.params_hash),
  digest: String(r.digest),
  principal: JSON.parse(String(r.principal)) as Principal,
  feed_item: r.feed_item === null ? null : String(r.feed_item),
  state: String(r.state) as ApprovalState,
  reply: r.reply === null ? null : (JSON.parse(String(r.reply)) as unknown),
  target: String(r.target ?? ""),
  summary: String(r.summary ?? ""),
  created_at: Number(r.created_at),
  expires_at: Number(r.expires_at),
  ended_at: r.ended_at === null ? null : Number(r.ended_at)
})

export const approvalByRequest = (sql: Sql, request: string): ApprovalRow | undefined => {
  const r = sql.exec<Raw>(`SELECT * FROM integration_approvals WHERE request = ?`, request).toArray()[0]
  return r ? decode(r) : undefined
}

export const approvalByKey = (sql: Sql, identity: string, key: string): ApprovalRow | undefined => {
  const r = sql.exec<Raw>(`SELECT * FROM integration_approvals WHERE identity = ? AND idempotency_key = ?`, identity, key).toArray()[0]
  return r ? decode(r) : undefined
}

/** Pending requests for one connection that have not expired (the flood guard counts these). */
export const pendingCount = (sql: Sql, connection: string, now: number): number =>
  Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM integration_approvals WHERE connection = ? AND state IN ('pending', 'running') AND expires_at > ?`, connection, now).toArray()[0]?.n ?? 0)

export const pendingCountFor = (sql: Sql, identity: string, now: number): number =>
  Number(sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM integration_approvals WHERE identity = ? AND state IN ('pending', 'running') AND expires_at > ?`, identity, now).toArray()[0]?.n ?? 0)

export const insertApproval = (sql: Sql, row: Omit<ApprovalRow, "feed_item" | "state" | "reply" | "ended_at">) => {
  sql.exec(
    `INSERT INTO integration_approvals (request, identity, idempotency_key, user, connection, op, params, params_hash, digest, principal, feed_item, state, reply, target, summary, created_at, expires_at, ended_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, 'pending', NULL, ?, ?, ?, ?, NULL)`,
    row.request, row.identity, row.idempotency_key, row.user, row.connection, row.op, JSON.stringify(row.params), row.params_hash, row.digest,
    JSON.stringify(row.principal), row.target, row.summary, row.created_at, row.expires_at
  )
}

export const setFeedItem = (sql: Sql, request: string, item: string) => sql.exec(`UPDATE integration_approvals SET feed_item = ? WHERE request = ?`, item, request)
export const deleteApproval = (sql: Sql, request: string) => sql.exec(`DELETE FROM integration_approvals WHERE request = ?`, request)

/**
 * Moves a request from one of `from` to a final state; returns false when it was in another state.
 * Every final state drops the params; a done run keeps the provider's reply.
 */
export const endApproval = (sql: Sql, request: string, state: Exclude<ApprovalState, "pending" | "running">, now: number, reply: unknown = null, from: ReadonlyArray<ApprovalState> = ["pending"]): boolean => {
  const row = approvalByRequest(sql, request)
  if (!row || !from.includes(row.state)) return false
  // Final: the params (a mail body, a message) go; op, target, summary, digest and outcome stay 30 days.
  sql.exec(`UPDATE integration_approvals SET state = ?, reply = ?, ended_at = ?, params = '{}' WHERE request = ?`, state, reply === null ? null : JSON.stringify(reply), now, request)
  return true
}

/** pending -> running before the provider call (expiry never ends a running request); false if it was not pending. */
export const startRun = (sql: Sql, request: string, now: number = Date.now()): boolean => {
  const row = approvalByRequest(sql, request)
  if (!row || row.state !== "pending") return false
  // Expired while the answer-time checks ran (approval-gate.ts deliverAnswers): final, never run.
  if (now >= row.expires_at) return (endApproval(sql, request, "expired", now), false)
  sql.exec(`UPDATE integration_approvals SET state = 'running' WHERE request = ?`, request)
  return true
}

/** running -> pending after a retryable failure, so the redelivered answer runs it again. */
export const backToPending = (sql: Sql, request: string) => sql.exec(`UPDATE integration_approvals SET state = 'pending' WHERE request = ? AND state = 'running'`, request)

/** A pending request past its time becomes expired (final); returns the row as it is now. */
export const settleExpiry = (sql: Sql, row: ApprovalRow, now: number): ApprovalRow => {
  if (row.state !== "pending" || now < row.expires_at) return row
  endApproval(sql, row.request, "expired", now)
  return { ...row, state: "expired", ended_at: now }
}

/** integration.approval.get: the person's own session reads the full request it is asked to approve. */
export const approvalView = (sql: Sql, principal: Principal, params: unknown, now: number) => {
  const row = approvalByRequest(sql, String((params as { request?: unknown } | null)?.request ?? ""))
  if (!row || principal.kind !== "session" || principal.user !== row.user) return { ok: false as const, code: "selector.not_found", message: "no such approval request" }
  const state = row.state === "pending" && now >= row.expires_at ? "expired" : row.state === "running" ? "pending" : row.state
  return { ok: true as const, value: { request: row.request, op: row.op, connection: row.connection, target: row.target, summary: row.summary, params: row.params, digest: row.digest, state, created_at: row.created_at, expires_at: row.expires_at }, revision: "" }
}

export const pruneApprovals = (sql: Sql, before: number) => sql.exec(`DELETE FROM integration_approvals WHERE ended_at IS NOT NULL AND ended_at < ?`, before)

/** The earliest time a pending request expires or an ended one leaves the table. */
export const nextApprovalAt = (sql: Sql): number | null => {
  const r = sql.exec<{ a: number | null; b: number | null }>(
    `SELECT (SELECT MIN(expires_at) FROM integration_approvals WHERE state IN ('pending', 'running')) AS a, (SELECT MIN(ended_at) FROM integration_approvals WHERE ended_at IS NOT NULL) AS b`
  ).toArray()[0]
  const times = [r?.a, r?.b === null || r?.b === undefined ? null : Number(r.b) + APPROVAL_RETENTION_MS].filter((t): t is number => typeof t === "number")
  return times.length ? Math.min(...times) : null
}

/**
 * A member left the team at `at` (cx-44j.47): their pending requests from before then end denied
 * and lose their params (a late delivery after a re-join keeps newer ones); returns how many.
 */
export const endForMember = (sql: Sql, user: string, at: number, now: number): number =>
  sql.exec(`UPDATE integration_approvals SET state = 'denied', ended_at = ?, params = '{}' WHERE user = ? AND state = 'pending' AND created_at <= ?`, now, user, at).rowsWritten

/** Expires every pending request whose time passed (the alarm calls this). */
export const expireDue = (sql: Sql, now: number) =>
  sql.exec(`UPDATE integration_approvals SET state = 'expired', ended_at = ?, params = '{}' WHERE state = 'pending' AND expires_at <= ?`, now, now)

const text = (v: unknown, max: number) => (typeof v === "string" ? v.replace(/\s+/g, " ").trim().slice(0, max) : "")
const sizeText = (v: unknown) => {
  const s = (v && typeof v === "object" ? v : {}) as Record<string, unknown>
  const n = (x: unknown) => (typeof x === "number" && Number.isFinite(x) ? x : null)
  return [n(s.cpu) !== null ? `${n(s.cpu)} vCPU` : "", n(s.memory_mb) !== null ? `${n(s.memory_mb)} MB memory` : "", n(s.disk_mb) !== null ? `${n(s.disk_mb)} MB disk` : ""].filter(Boolean).join(", ")
}
const list = (v: unknown) => (Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : typeof v === "string" ? [v] : [])

/**
 * What the person sees in the feed before opening the approval view: the target (recipient,
 * channel, repository, calendar) and a short summary (a mail subject, an event title). Never a
 * mail body or a message text.
 */
export const describeRequest = (op: string, p: Record<string, unknown>): { target: string; summary: string } => {
  switch (op) {
    case "mail.send": {
      const to = [...list(p.to), ...list(p.cc), ...list(p.bcc)]
      return { target: text(to.slice(0, 5).join(", ") + (to.length > 5 ? ` and ${to.length - 5} more` : ""), 300), summary: text(p.subject, 200) }
    }
    case "calendar.event.create":
      return { target: text(`${text(p.calendar_id, 100) || "calendar"}${Array.isArray(p.attendees) && p.attendees.length ? `, ${p.attendees.length} attendees` : ""}`, 300), summary: text(p.summary, 200) }
    case "calendar.event.respond":
      return { target: text(`${text(p.calendar_id, 100) || "calendar"} event ${text(p.event_id, 100)}`, 300), summary: text(p.response, 40) }
    case "github.issue.comment":
      return { target: text(`${text(p.repo, 200)}#${String(p.issue ?? "")}`, 300), summary: "" }
    case "slack.post_as_bot":
      return { target: text(p.channel, 100), summary: "" }
    // Cloud requests from an install (CloudDO, cx-wb5.65): the machine or snapshot, and the size.
    case "cloud.machine.create":
      return { target: text(p.name, 100) || "new machine", summary: text(`${sizeText(p.size)}${p.from_snapshot ? ` from snapshot ${text(p.from_snapshot, 40)}` : ""}`, 200) }
    case "cloud.machine.resize":
      return { target: text(p.machine, 100), summary: sizeText(p.size) }
    case "cloud.machine.delete":
    case "cloud.snapshot.create":
      return { target: text(p.machine, 100), summary: text(p.name, 100) }
    case "cloud.snapshot.delete":
    case "cloud.snapshot.restore":
      return { target: text(p.snapshot, 100), summary: text(p.name, 100) }
    default:
      return { target: text(p.connection, 100), summary: "" }
  }
}
