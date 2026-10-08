import type { OutboxItem, Principal } from "@cmux/ownership"
import type { FeedItem } from "@cmux/protocol"

/**
 * G8 gateway approvals on the feed side (integrations-plan.md section 3). The ConnectionDO of a
 * team posts an `approve` request through FeedDO.integrationApproval as the system principal
 * `system:connections:<team>` (poster kind integration); the prompt's action input carries
 * `{approval: {team, request, digest}}`. When the person answers or declines it, the feed sends
 * the decision to that ConnectionDO (outbox), which runs the op once or ends the request.
 */
export const integrationPoster = (p: Principal): string | null =>
  p.kind === "system" && p.user && p.identity.startsWith("system:connections:") ? p.identity.slice("system:connections:".length) : null

/** The approval an integration approve item carries, when its poster scope is the named team's ConnectionDO. */
export const approvalOf = (item: FeedItem): { team: string; request: string; digest: string } | null => {
  if (item.poster.kind !== "integration" || item.kind !== "approve") return null
  const a = ((item.prompt as { action?: { input?: { approval?: unknown } } } | undefined)?.action?.input?.approval ?? null) as Record<string, unknown> | null
  if (!a || typeof a.team !== "string" || typeof a.request !== "string" || typeof a.digest !== "string" || !a.team) return null
  // Only the team that posted the item hears the decision.
  if (item.poster.scope !== `system:connections:${a.team}`) return null
  return { team: a.team, request: a.request, digest: a.digest }
}

/** The outbox item that tells the posting ConnectionDO the person's decision, or none. */
export const approvalDecision = (item: FeedItem, decision: "allow" | "deny", ssoTeam?: string): ReadonlyArray<OutboxItem> => {
  const a = approvalOf(item)
  if (!a) return []
  // The answering session's SSO team: the posting team checks it at answer time when it enforces SSO.
  const sso = decision === "allow" && ssoTeam ? { sso_team: ssoTeam } : {}
  return [{ kind: "integration.approval.answered", entity: `approval:${a.request}`, payload: { request: a.request, decision, digest: a.digest, ...sso }, target: { class: "ConnectionDO", name: a.team } }]
}
