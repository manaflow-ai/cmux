/**
 * G8 integration approvals in the dashboard (integrations-plan.md section 3). A send-external,
 * money or destructive provider op from an agent, automation or app waits in the API: the team's
 * ConnectionDO posts an `approve` feed request (poster kind integration) whose prompt carries
 * `{approval: {team, request, digest}}`, and only this session may read the full request
 * (`integration.approval.get`) and answer it (`feed.answer`).
 *
 * The dashboard offers Approve only after it recomputed the digest from the parameters it shows
 * and found it equal to the feed request's digest, so the person approves what they read.
 */

export type ApprovalStatus = "pending" | "running" | "answered" | "approved" | "revoked" | "denied" | "expired" | "stale" | "withdrawn"
/** "error": this browser could not hash (no secure context); Approve stays off. Null: nothing to check (final). */
export type DigestCheck = "match" | "mismatch" | "error" | null

/** integration.approval.get (packages/protocol/src/integrations.ts IntegrationApprovalGet). */
export interface ApprovalView {
  readonly request: string
  readonly op: string
  readonly connection: string
  readonly target: string
  readonly summary: string
  readonly params: unknown
  readonly digest: string
  readonly state: "pending" | "done" | "denied" | "expired"
  readonly created_at: number
  readonly expires_at: number
}

/** The integration approve request as the feed item carries it (no message body). */
export interface ParsedApproval {
  readonly item: string
  readonly request: string
  readonly digest: string
  readonly team: string
  readonly op: string
  readonly target: string
  readonly summary: string
  readonly risk: string
  readonly feedState: string
  readonly answer: "allow" | "deny" | null
  readonly cancelReason: string | null
  readonly createdAt: number
  readonly expiresAt: number
}

const REQUEST = /^apr_[a-f0-9]{32}$/
const DIGEST = /^sha256:[a-f0-9]{64}$/

const obj = (v: unknown): Record<string, unknown> | null => (v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : null)
const str = (v: unknown) => (typeof v === "string" ? v : "")

/** The approval in a feed item, or null when the item is not an integration approve request. */
export const parseApproval = (item: unknown): ParsedApproval | null => {
  const i = obj(item)
  if (!i || i.kind !== "approve" || obj(i.poster)?.kind !== "integration") return null
  const action = obj(obj(i.prompt)?.action)
  const input = obj(action?.input)
  const a = obj(input?.approval)
  if (!a || !REQUEST.test(str(a.request)) || !DIGEST.test(str(a.digest)) || !str(a.team)) return null
  // The same check the API makes (feed-approvals.ts): only the posting team's ConnectionDO, or its CloudDO
  // for a Cloud request from a device (cx-wb5.65), hears the answer.
  const scope = obj(i.poster)?.scope
  if (scope !== `system:connections:${str(a.team)}` && scope !== `system:cloud:${str(a.team)}`) return null
  const answer = obj(obj(i.answer)?.value)?.decision
  return {
    item: str(i.id),
    request: str(a.request),
    digest: str(a.digest),
    team: str(a.team),
    op: str(action?.tool),
    target: str(input?.target),
    summary: str(input?.summary),
    risk: str(action?.risk),
    feedState: str(i.state),
    answer: answer === "allow" || answer === "deny" ? answer : null,
    cancelReason: str(obj(i.cancel)?.reason) || null,
    createdAt: Number(i.created_at) || 0,
    expiresAt: Number(i.expires_at) || 0
  }
}

/** Canonical JSON (sorted keys), the same as @cmux/ownership canonicalJson that the API hashes. */
export const canonicalJson = (value: unknown): string =>
  JSON.stringify(value, (_k, v: unknown) =>
    v && typeof v === "object" && !Array.isArray(v)
      ? Object.fromEntries(Object.entries(v as Record<string, unknown>).sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
      : v
  ) ?? "null"

/** sha256 of the canonical op and params, as `sha256:<hex>` (approval-gate.ts approvalDigest). */
export const requestDigest = async (op: string, params: unknown): Promise<string> => {
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(canonicalJson({ op, params }))))
  return `sha256:${Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("")}`
}

/**
 * Whether the request the session read is the one the feed asked about: same op, same digest,
 * and parameters that hash to it. Null for a final request (its parameters are deleted).
 */
export const checkDigest = async (a: ParsedApproval, view: ApprovalView): Promise<DigestCheck> => {
  if (view.state !== "pending") return null
  if (view.op !== a.op || view.digest !== a.digest) return "mismatch"
  try {
    return (await requestDigest(view.op, view.params)) === a.digest ? "match" : "mismatch"
  } catch {
    return "error"
  }
}

/**
 * What the person sees. The API's final states win (approved = sent once; denied, or revoked when
 * the person approved but the caller lost its grant; expired); a digest that does not match is
 * stale; otherwise the feed answer shows until the API settles it. Without a view (pruned, another
 * team, a failed read) the feed item decides, and an approval's outcome stays unknown (answered).
 */
export const approvalStatus = (a: ParsedApproval, view: ApprovalView | null, digest: DigestCheck, now: number): ApprovalStatus => {
  if (view?.state === "done") return "approved"
  if (view?.state === "denied") return a.answer === "allow" ? "revoked" : "denied"
  if (view?.state === "expired") return "expired"
  if (digest === "mismatch") return "stale"
  if (a.answer === "deny" || a.cancelReason === "declined") return "denied"
  if (a.answer === "allow") return view ? "running" : "answered"
  if (a.feedState === "cancelled") return "withdrawn"
  if (a.feedState === "expired" || now >= (view?.expires_at ?? a.expiresAt)) return "expired"
  return "pending"
}

export const canApprove = (status: ApprovalStatus, digest: DigestCheck) => status === "pending" && digest === "match"
/** Deny stays open for a stale request too (while the feed item is open): it ends the waiting op and runs nothing. */
export const canDeny = (a: ParsedApproval, status: ApprovalStatus) => a.feedState === "open" && (status === "pending" || status === "stale")
