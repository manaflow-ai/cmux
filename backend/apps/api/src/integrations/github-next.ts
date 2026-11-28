/**
 * What the person does next, for each GitHub refusal the API answers (GitHub integration audit fix 10: "the API adds
 * `next` to the error body"). One line per code (and per policy.denied reason), the same steps cmux-host's
 * `github_cli::next_step` prints after a refused git or gh, so a client that only shows `error.next` still tells the
 * person what to do. `action` is the cmux action that does it (a chat's Connect GitHub card and the console's button
 * run it); none when only someone else (an admin, an owner) can fix it, or when waiting is the fix.
 *
 * Codes without a step here (request.invalid, internal errors) get no `next`.
 */
export type GitHubNext = { readonly next: string; readonly next_action?: "accounts.githubConnect" }

/** The words every connect step uses (cmux-host lib.rs CONNECT_GITHUB, shortened for one line). */
export const CONNECT_GITHUB = "choose Connect GitHub in cmux (or run `cmux accounts github-connect` on your Mac)"
const again = "then run the same step again"

const BY_REASON: Readonly<Record<string, GitHubNext>> = {
  owner_not_connected: { next: `If you own this repository's account, ${CONNECT_GITHUB} and install the App there; otherwise ask its owner to install the cmux GitHub App on it, ${again}.`, next_action: "accounts.githubConnect" },
  connection_other_owner: { next: `Pick the team's GitHub connection on the repository's owner, or ${CONNECT_GITHUB} and install the App there, ${again}.`, next_action: "accounts.githubConnect" },
  repo_not_granted: { next: `Add the repository to the cmux GitHub App on GitHub's page, or ${CONNECT_GITHUB} as someone who can see it, ${again}.`, next_action: "accounts.githubConnect" },
  repo_not_allowed: { next: `Ask a team admin to add the repository to the team's GitHub allowlist in the cmux console, ${again}.` },
  permissions_not_granted: { next: `An owner of the GitHub account approves the cmux GitHub App's new permissions on GitHub's page, ${again}.` },
  workflows_not_allowed: { next: `Ask a team admin to allow workflow file changes in the team's GitHub policy in the cmux console, ${again}.` },
}

const BY_CODE: Readonly<Record<string, GitHubNext>> = {
  "integration.not_found": { next: `GitHub is not connected for this cmux team: ${CONNECT_GITHUB}, ${again}.`, next_action: "accounts.githubConnect" },
  "github.not_connected": { next: `GitHub is not connected for this cmux team: ${CONNECT_GITHUB}, ${again}.`, next_action: "accounts.githubConnect" },
  needs_reauth: { next: `The team's GitHub connection needs linking again: ${CONNECT_GITHUB}, ${again}.`, next_action: "accounts.githubConnect" },
  "policy.denied": { next: `The team's GitHub connection does not cover this: ${CONNECT_GITHUB} and pick the repository on GitHub's page, or ask a team admin to allow it.`, next_action: "accounts.githubConnect" },
  rate_limited: { next: "GitHub asked cmux to slow down: wait for the time shown, then try again." },
  "integration.unavailable": { next: "cmux could not reach GitHub or its own services just now: try again in a minute." },
  "auth.required": { next: "Sign in to cmux again, then try again." },
  "integration.state_invalid": { next: `This connection link expired or belongs to another sign-in: ${CONNECT_GITHUB} to start again.`, next_action: "accounts.githubConnect" },
}

/** The next step for `code` (and, for policy.denied, its `reason`), or undefined when the table has none. */
export const githubNext = (code: string, reason?: string): GitHubNext | undefined =>
  (code === "policy.denied" && reason !== undefined ? BY_REASON[reason] : undefined) ?? BY_CODE[code]

/**
 * An organization member's install that GitHub turned into a request to the organization's owners (`setup_action=request`):
 * not expired, not refused; nothing to do until an owner approves it.
 */
export const GITHUB_OWNER_REQUEST_NEXT: GitHubNext = {
  next: `Wait for an owner of the GitHub organization to approve the cmux GitHub App; GitHub emails them the request. Then ${CONNECT_GITHUB} again.`,
}

type OpReply = { readonly ok: boolean; readonly error?: { readonly code: string; readonly message: string; readonly details?: unknown } }

/**
 * `reply` with `error.next` (and `error.next_action`) added when the table has a step for its code. `ownerRequest`: the
 * completion GitHub sent for an install request (`setup_action=request`), whose refusal is the pending approval.
 */
export const withGitHubNext = <R extends OpReply>(reply: R, ownerRequest = false): R => {
  if (reply.ok || !reply.error) return reply
  const reason = (reply.error.details as { reason?: unknown } | undefined)?.reason
  const step = ownerRequest ? GITHUB_OWNER_REQUEST_NEXT : githubNext(reply.error.code, typeof reason === "string" ? reason : undefined)
  return step ? { ...reply, error: { ...reply.error, ...step } } : reply
}
