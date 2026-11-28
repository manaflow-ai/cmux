import type { OutboxItem, Principal } from "@cmux/ownership"
import type { FeedItem } from "@cmux/protocol"

/**
 * G8 gateway approvals on the feed side (integrations-plan.md section 3). A team's ConnectionDO
 * (integration ops) or CloudDO (Cloud money and destructive ops from an install, cx-wb5.65) posts
 * an `approve` request through FeedDO.integrationApproval as the system principal
 * `system:<source>:<team>` (poster kind integration); the prompt's action input carries
 * `{approval: {team, request, digest}}`. When the person answers or declines it, the feed sends
 * the decision to that owner (outbox), which runs the op once or ends the request.
 */
export type ApprovalSource = "connections" | "cloud"
const OWNER_CLASS: Record<ApprovalSource, string> = { connections: "ConnectionDO", cloud: "CloudDO" }
const POSTER = /^system:(connections|cloud):(.+)$/

/** The posting owner of a system principal that may post approval requests, or null. */
export const approvalPoster = (identity: string): { source: ApprovalSource; team: string } | null => {
  const m = POSTER.exec(identity)
  return m ? { source: m[1] as ApprovalSource, team: m[2]! } : null
}

export const integrationPoster = (p: Principal): string | null => (p.kind === "system" && p.user ? (approvalPoster(p.identity)?.team ?? null) : null)

/** The approval an integration approve item carries, when its poster scope is the named team's posting owner. */
export const approvalOf = (item: FeedItem): { team: string; request: string; digest: string; source: ApprovalSource } | null => {
  if (item.poster.kind !== "integration" || item.kind !== "approve") return null
  const a = ((item.prompt as { action?: { input?: { approval?: unknown } } } | undefined)?.action?.input?.approval ?? null) as Record<string, unknown> | null
  if (!a || typeof a.team !== "string" || typeof a.request !== "string" || typeof a.digest !== "string" || !a.team) return null
  // Only the owner of the team that posted the item hears the decision.
  const poster = approvalPoster(item.poster.scope ?? "")
  if (!poster || poster.team !== a.team) return null
  return { team: a.team, request: a.request, digest: a.digest, source: poster.source }
}

/** The outbox item that tells the posting owner the person's decision, or none. */
export const approvalDecision = (item: FeedItem, decision: "allow" | "deny", ssoTeam?: string): ReadonlyArray<OutboxItem> => {
  const a = approvalOf(item)
  if (!a) return []
  // The answering session's SSO team: the posting team checks it at answer time when it enforces SSO.
  const sso = decision === "allow" && ssoTeam ? { sso_team: ssoTeam } : {}
  return [{ kind: "integration.approval.answered", entity: `approval:${a.request}`, payload: { request: a.request, decision, digest: a.digest, ...sso }, target: { class: OWNER_CLASS[a.source], name: a.team } }]
}
