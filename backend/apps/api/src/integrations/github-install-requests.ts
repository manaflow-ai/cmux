import { ProviderError } from "./provider-core.ts"

/**
 * GitHub App install requests, and telling the person who asked when an owner approves one.
 *
 * An organization member who may not install the cmux GitHub App gets a request instead: GitHub sends the owners an
 * email and comes back to cmux with `setup_action=request`, a `code` (user authorization during installation is on) and
 * no installation. The completion exchanges that code once for the requester's GitHub user id (GET /user) and records
 * (GitHub user id -> cmux user, team, connection) in the team's ConnectionDO, plus an AccountIndexDO link under
 * `github:requester:<id>` so a webhook can find the team.
 *
 * When an owner approves, GitHub sends `installation.created` whose `requester` is the member who asked (null for a
 * direct install). The webhook route (ingress/provider-hook.ts) looks up that requester's index and each team's
 * ConnectionDO tells its recorded cmux users: a feed notice (pushed to their devices like any notice) and an
 * `integration.changed` frame on their watching feed sockets, so an open app re-reads GitHub at once.
 *
 * Nothing links by itself: the requester's GitHub token is not kept, so nothing proves what they can reach through the
 * new installation. They choose Connect GitHub once more; GitHub shows the existing installation and completion proves
 * access with their own token, as for any link. Only the GitHub id the requester's own code proved is matched; a
 * request without a usable code records nothing (the person still sees "asked your org admin", just no notice later).
 */

/** How long a request waits for an approval before it is forgotten (an owner may take days; GitHub has no cancel webhook). */
export const INSTALL_REQUEST_TTL_MS = 30 * 24 * 3600_000

/** The AccountIndexDO name holding the teams where this GitHub user asked for an install. */
export const requesterIndexKey = (githubId: number) => `github:requester:${githubId}`

/** The GitHub account a request's code proved: who asked. */
export interface InstallRequester {
  readonly github_id: number
  readonly login: string
}

/** The completion's refusal for an install request; carries the requester when their code proved who they are. */
export class GithubInstallRequested extends ProviderError {
  constructor(readonly requester: InstallRequester | undefined) {
    super("integration.state_invalid", "GitHub sent your request to install the cmux GitHub App to the organization's owners. When an owner approves it, choose Connect GitHub in cmux again")
  }
}

export const createInstallRequestTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS github_install_requests (
    github_id INTEGER NOT NULL, user TEXT NOT NULL, connection TEXT NOT NULL, login TEXT NOT NULL, requested_at INTEGER NOT NULL,
    PRIMARY KEY (github_id, user))`)

/** Records that `user` asked as `requester` (a later ask by the same person replaces the earlier one). */
export const recordInstallRequest = (sql: SqlStorage, requester: InstallRequester, user: string, connection: string, now: number) => {
  sql.exec(`DELETE FROM github_install_requests WHERE requested_at < ?`, now - INSTALL_REQUEST_TTL_MS)
  sql.exec(
    `INSERT OR REPLACE INTO github_install_requests (github_id, user, connection, login, requested_at) VALUES (?, ?, ?, ?, ?)`,
    requester.github_id, user, connection, requester.login, now
  )
}

/** The cmux users waiting on `githubId`'s requests here (unexpired). */
export const pendingInstallRequests = (sql: SqlStorage, githubId: number, now: number): Array<string> =>
  sql
    .exec<{ user: string }>(`SELECT user FROM github_install_requests WHERE github_id = ? AND requested_at >= ? ORDER BY user`, githubId, now - INSTALL_REQUEST_TTL_MS)
    .toArray()
    .map((r) => String(r.user))

/** Forgets `githubId`'s requests once they were told (a second approval notifies no one). */
export const forgetInstallRequests = (sql: SqlStorage, githubId: number) => sql.exec(`DELETE FROM github_install_requests WHERE github_id = ?`, githubId)

/** An owner approved a member's request: what the `installation.created` delivery says. */
export interface InstallApproval {
  readonly requester_id: number
  readonly installation_id: number
  /** The organization the App is now installed on. */
  readonly account: string
  readonly delivery_id: string
}

const positive = (v: unknown): number | undefined => (typeof v === "number" && Number.isSafeInteger(v) && v > 0 ? v : undefined)

/** The approval a verified GitHub delivery carries, or null (any other event, or a direct install with no requester). */
export const installApprovalOf = (d: { readonly event: string; readonly delivery_id: string; readonly payload: unknown }): InstallApproval | null => {
  if (d.event !== "installation.created") return null
  const p = (d.payload ?? {}) as { requester?: { id?: unknown } | null; installation?: { id?: unknown; account?: { login?: unknown } } }
  const requester_id = positive(p.requester?.id)
  const installation_id = positive(p.installation?.id)
  if (requester_id === undefined || installation_id === undefined) return null
  const login = p.installation?.account?.login
  return { requester_id, installation_id, account: typeof login === "string" && login ? login.slice(0, 100) : String(installation_id), delivery_id: d.delivery_id }
}

/** The feed notice the person who asked receives (feed.post params; FeedDO.integrationNotice posts it). */
export const approvalNotice = (a: InstallApproval) => ({
  type: "notice" as const,
  kind: "notice",
  title: `${a.account} approved the cmux GitHub App`.slice(0, 200),
  body: `An owner of ${a.account} approved your request to install the cmux GitHub App. Choose Connect GitHub in cmux to finish connecting it.`,
  priority: "high" as const,
  dedupe_key: `github-install-approved:${a.installation_id}`,
  thread: "github-install-request",
  expires_in_ms: 7 * 24 * 3600_000,
  poster: { kind: "integration" as const, label: "GitHub" }
})

/**
 * The frame the person's watching feed sockets receive: the usual `integration.changed` (clients re-read GitHub on
 * any), with no repository changes, `more` (read everything again), and the approved installation.
 */
export const approvalFrame = (a: InstallApproval) => ({
  t: "integration.changed" as const,
  provider: "github" as const,
  changes: [] as Array<never>,
  more: true as const,
  installation: { id: a.installation_id, account: a.account, approved: true as const }
})
