import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { DisplayName, TeamId, UserId } from "./schemas.ts"

/**
 * Integration connections (spec integrations.md). The ConnectionDO of the
 * owner team holds connection records; provider tokens live encrypted beside
 * it and never leave the gateway: agents call provider ops and the owner uses
 * the token server-side.
 */

export const ConnectionId = Schema.String.check(Schema.isPattern(/^conn_[a-z0-9]{20}$/)).annotate({
  identifier: "ConnectionId",
  description: "One integration connection (a provider account linked to a team)."
})

export const IntegrationProvider = Schema.Literals(["github", "linear", "slack", "google_calendar", "gmail"]).annotate({ identifier: "IntegrationProvider" })
export type IntegrationProvider = typeof IntegrationProvider.Type

export const ConnectionStatus = Schema.Literals(["pending", "active", "needs_reauth", "error", "revoked", "expired"]).annotate({ identifier: "ConnectionStatus" })

/**
 * A connection the user started but never approved at the provider becomes
 * `expired` this long after it was created (30 minutes, twice the 15-minute
 * OAuth state lifetime). The owner's alarm expires it once; a provider callback
 * that arrives later is refused. A new Connect click starts a fresh one.
 */
export const PENDING_CONNECTION_TTL_MS = 30 * 60_000

/** Expired connections leave the owner's state this long after they expired (the projection keeps the row). */
export const EXPIRED_CONNECTION_RETENTION_MS = 24 * 3600_000

export const Connection = Schema.Struct({
  id: ConnectionId,
  owner: TeamId,
  created_by: UserId,
  provider: IntegrationProvider,
  /** Non-secret provider account: key (for example github:installation:42), display name, URL. */
  account: Schema.NullOr(Schema.Struct({ key: Schema.String, name: Schema.String, url: Schema.optionalKey(Schema.String) })),
  scopes_requested: Schema.Array(Schema.String),
  scopes_granted: Schema.Array(Schema.String),
  status: ConnectionStatus,
  status_detail: Schema.optionalKey(Schema.String),
  sharing: Schema.Literals(["private", "team"]),
  /**
   * Provider resources this connection may act on. GitHub: the repositories the
   * linking user could access in the installation (`null` = the whole
   * installation, when the team policy says so).
   */
  resources: Schema.optionalKey(Schema.Struct({ repos: Schema.NullOr(Schema.Array(Schema.String)) })),
  created_at: Schema.Int,
  updated_at: Schema.Int
}).annotate({ identifier: "Connection" })

/** `owner/repo`, or `owner/*` for every repository of an account. */
export const RepoPattern = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_.-]{1,100}\/([A-Za-z0-9_.-]{1,100}|\*)$/)).annotate({ identifier: "RepoPattern" })

/**
 * The team's integration policy (enterprise-ready from day one). A team admin
 * sets it, or a managed source (SSO-provisioned team policy, MDM profile)
 * applies it and locks it. The enterprise lead wires the managed sources
 * through the internal op `integration.policy.apply_managed`.
 */
export const TeamIntegrationPolicy = Schema.Struct({
  /** Providers members may connect; null = every provider this deployment supports. */
  allowed_providers: Schema.NullOr(Schema.Array(IntegrationProvider)),
  github: Schema.Struct({
    /** linking_user_repos (default): ops and events only for repositories the linking user can access. installation: the whole installation. */
    scope: Schema.Literals(["linking_user_repos", "installation"]),
    /** Only an organization admin (or the account owner, for a user installation) may link. */
    require_org_admin: Schema.Boolean,
    /** When set, ops and events are further limited to these repositories. */
    repo_allowlist: Schema.NullOr(Schema.Array(RepoPattern).check(Schema.isMaxLength(500)))
  }),
  /** team_policy: TeamDO's TeamPolicy (the single writer, spec/enterprise.md 4) pushed here for enforcement. */
  source: Schema.Literals(["default", "admin", "sso", "mdm", "team_policy"]),
  /** Managed (sso, mdm, team_policy) policies are locked: change them where they are owned. */
  locked: Schema.Boolean,
  updated_at: Schema.NullOr(Schema.Int),
  updated_by: Schema.NullOr(Schema.String)
}).annotate({ identifier: "TeamIntegrationPolicy" })
export type TeamIntegrationPolicy = typeof TeamIntegrationPolicy.Type

export const DEFAULT_INTEGRATION_POLICY: TeamIntegrationPolicy = {
  allowed_providers: null,
  github: { scope: "linking_user_repos", require_org_admin: false, repo_allowlist: null },
  source: "default",
  locked: false,
  updated_at: null,
  updated_by: null
}

const PolicyFields = Schema.Struct({
  allowed_providers: Schema.optionalKey(Schema.NullOr(Schema.Array(IntegrationProvider))),
  github: Schema.optionalKey(
    Schema.Struct({
      scope: Schema.optionalKey(Schema.Literals(["linking_user_repos", "installation"])),
      require_org_admin: Schema.optionalKey(Schema.Boolean),
      repo_allowlist: Schema.optionalKey(Schema.NullOr(Schema.Array(RepoPattern).check(Schema.isMaxLength(500))))
    })
  )
})

export const IntegrationPolicyGet = def({
  name: "integration.policy.get",
  owner: "cloud:ConnectionDO",
  class: "read",
  risk: "read",
  target: "connection",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: TeamIntegrationPolicy,
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "Read the team's integration policy (allowed providers, GitHub repository scope).",
  cli: { path: "integration policy", visible: true },
  mcp: { expose: "opt_in", group: "integration" }
})

/** G8: the approval view reads the exact request an agent, automation or app asked to run. */
export const IntegrationApprovalGet = def({
  name: "integration.approval.get",
  owner: "cloud:ConnectionDO",
  class: "read",
  risk: "read",
  target: "connection",
  principals: ["session"],
  params: Schema.Struct({ request: Schema.String.check(Schema.isPattern(/^apr_[a-f0-9]{32}$/)) }),
  result: Schema.Struct({
    request: Schema.String,
    op: Schema.String,
    connection: Schema.String,
    target: Schema.String,
    summary: Schema.String,
    params: Schema.Unknown,
    digest: Schema.String,
    state: Schema.Literals(["pending", "done", "denied", "expired"]),
    created_at: Schema.Number,
    expires_at: Schema.Number
  }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found"],
  docs: "Read a provider op that waits for your approval (G8): the op, target, summary, full parameters and the digest the feed request shows. Parameters are deleted when the request ends. Only your own session reads it.",
  cli: { path: "integration approval", visible: true },
  mcp: { expose: "never", group: "integration" }
})

export const IntegrationPolicySet = def({
  name: "integration.policy.set",
  owner: "cloud:ConnectionDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "connection",
  principals: ["session"],
  params: PolicyFields,
  result: TeamIntegrationPolicy,
  errors: [...mutationErrors, "policy.locked"],
  docs: "Change the team's integration policy (team admins; refused while an SSO or MDM policy locks it).",
  cli: { path: "integration policy set", visible: true },
  mcp: { expose: "never", group: "integration" }
})
export type Connection = typeof Connection.Type

const Scopes = Schema.Array(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))).check(Schema.isMaxLength(30))

export const IntegrationConnect = def({
  name: "integration.connect",
  owner: "cloud:ConnectionDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "connection",
  principals: ["session"],
  params: Schema.Struct({
    provider: IntegrationProvider,
    scopes: Schema.optionalKey(Scopes),
    sharing: Schema.optionalKey(Schema.Literals(["private", "team"]))
  }),
  result: Schema.Struct({ connection: Connection, authorize_url: Schema.String }),
  errors: [...mutationErrors, "integration.not_configured", "integration.limit", "policy.denied"],
  docs: "Start connecting a provider account: returns a pending connection and the provider URL a human opens to approve it.",
  cli: { path: "integration connect", visible: true },
  mcp: { expose: "never", group: "integration" }
})

export const IntegrationComplete = def({
  name: "integration.complete",
  owner: "cloud:ConnectionDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "connection",
  principals: ["session"],
  params: Schema.Struct({
    state: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(4000)),
    code: Schema.optionalKey(Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(2000))),
    installation_id: Schema.optionalKey(Schema.String.check(Schema.isPattern(/^[0-9]{1,20}$/))),
    setup_action: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(40)))
  }),
  result: Connection,
  errors: [...mutationErrors, "integration.not_configured", "integration.state_invalid", "mutation.indeterminate"],
  docs: "Finish a connection from the provider's redirect (the signed-in user must be the one who started it).",
  cli: { path: "", visible: false },
  mcp: { expose: "never", group: "integration" }
})

export const IntegrationRevoke = def({
  name: "integration.revoke",
  owner: "cloud:ConnectionDO",
  class: "mutation",
  risk: "destructive",
  target: "connection",
  principals: ["session"],
  params: Schema.Struct({ connection: ConnectionId }),
  result: Connection,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Disconnect: deletes the stored provider credential at once and marks the connection revoked.",
  cli: { path: "integration revoke", visible: true },
  mcp: { expose: "never", group: "integration" }
})

export const IntegrationList = def({
  name: "integration.list",
  owner: "cloud:ConnectionDO",
  class: "read",
  risk: "read",
  target: "connection",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ connections: Schema.Array(Connection), providers: Schema.Array(Schema.Struct({ provider: IntegrationProvider, configured: Schema.Boolean })), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List the team's connections the caller may use (no secrets) and which providers this deployment can connect.",
  cli: { path: "integration list", visible: true },
  mcp: { expose: "default", group: "integration" }
})

const providerOp = <P extends Schema.Top>(name: string, risk: CloudOpDef["risk"], params: P, docs: string) =>
  def({
    name,
    owner: "cloud:ConnectionDO",
    class: "mutation",
    risk,
    target: "connection",
    principals: ["session", "install"],
    params,
    result: Schema.Unknown,
    errors: [...mutationErrors, "selector.not_found", "integration.unavailable", "provider.error", "mutation.indeterminate", "policy.denied"],
    docs,
    cli: { path: name.replace(/\./g, " "), visible: true },
    mcp: { expose: "default", group: name.split(".")[0]! }
  })

const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))

export const GitHubIssueComment = providerOp(
  "github.issue.comment",
  "send-external",
  Schema.Struct({ connection: ConnectionId, repo: Schema.String.check(Schema.isPattern(/^(?!\.{1,2}\/)[A-Za-z0-9_.-]{1,100}\/(?!\.{1,2}$)[A-Za-z0-9_.-]{1,100}$/)), issue: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 1e9 })), body: Text(65_000) }),
  "Comment on a GitHub issue or pull request as the cmux GitHub App installation."
)

export const LinearIssueCreate = providerOp(
  "linear.issue.create",
  "mutate-shared",
  Schema.Struct({ connection: ConnectionId, team_id: Text(100), title: Text(500), description: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(100_000))) }),
  "Create a Linear issue in a Linear team as the cmux app."
)

export const SlackPostAsBot = providerOp(
  "slack.post_as_bot",
  "send-external",
  Schema.Struct({ connection: ConnectionId, channel: Schema.String.check(Schema.isPattern(/^[A-Z0-9]{2,30}$/)), text: Text(40_000) }),
  "Post a message to a Slack channel as the cmux bot."
)

export const LinearTeamsList = def({
  name: "linear.teams.list",
  owner: "cloud:ConnectionDO",
  class: "read",
  risk: "read",
  target: "connection",
  principals: ["session", "install"],
  params: Schema.Struct({ connection: ConnectionId }),
  result: Schema.Struct({ teams: Schema.Array(Schema.Struct({ id: Schema.String, key: Schema.String, name: Schema.String })) }),
  errors: ["auth.unauthenticated", "auth.forbidden", "selector.not_found", "integration.unavailable", "provider.error"],
  docs: "List the Linear teams this connection can reach (ids for linear.issue.create).",
  cli: { path: "linear teams", visible: true },
  mcp: { expose: "default", group: "linear" }
})

/** Provider reads: no idempotency key, no effect; answered by the gateway with the stored token. */
export const providerReadOpNames: ReadonlySet<string> = new Set([LinearTeamsList.name])

export const integrationOps = [
  IntegrationConnect,
  IntegrationComplete,
  IntegrationRevoke,
  IntegrationList,
  IntegrationPolicyGet,
  IntegrationApprovalGet,
  IntegrationPolicySet,
  GitHubIssueComment,
  LinearIssueCreate,
  LinearTeamsList,
  SlackPostAsBot
] as const
export const providerOpNames: ReadonlySet<string> = new Set([GitHubIssueComment.name, LinearIssueCreate.name, SlackPostAsBot.name])

const internal = (name: string, params: Schema.Top, docs: string): CloudOpDef =>
  ({
    name,
    owner: "cloud:ConnectionDO",
    class: "mutation",
    risk: "mutate-own",
    target: "connection",
    principals: ["system"],
    params,
    result: Schema.Unknown,
    errors: [],
    docs,
    cli: { path: "", visible: false },
    mcp: { expose: "never", group: "internal" }
  }) as CloudOpDef

export const ConnectionActivateParams = Schema.Struct({
  connection: ConnectionId,
  account: Schema.Struct({ key: Schema.String, name: DisplayName, url: Schema.optionalKey(Schema.String) }),
  scopes_granted: Schema.Array(Schema.String),
  resources: Schema.optionalKey(Schema.Struct({ repos: Schema.NullOr(Schema.Array(Schema.String)) }))
})

export const PolicyApplyManagedParams = Schema.Struct({
  source: Schema.Literals(["sso", "mdm", "team_policy"]),
  policy: PolicyFields,
  /** Who or what applied it (for example an IdP connection id or an MDM profile id). */
  applied_by: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200))
})
export const ConnectionStatusParams = Schema.Struct({
  connection: ConnectionId,
  status: Schema.Literals(["active", "needs_reauth", "error"]),
  detail: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(300)))
})

/** Ops only the ConnectionDO submits for itself (after an external effect). Not exported to the catalog. */
export const connectionInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("connection.activate", ConnectionActivateParams, "Internal: the provider approved; the credential is stored."),
  internal("connection.status", ConnectionStatusParams, "Internal: a refresh, call or provider event changed the connection's health."),
  internal(
    "connection.expire",
    // `at` is the alarm's wake instant (the owner's own clock reading; only the owner submits this op).
    Schema.Struct({ connection: ConnectionId, at: Schema.Int }),
    "Internal: a pending connection outlived PENDING_CONNECTION_TTL_MS."
  ),
  internal("connection.forget", Schema.Struct({ connection: ConnectionId, at: Schema.Int }), "Internal: drop an expired connection from owner state after EXPIRED_CONNECTION_RETENTION_MS."),
  internal("integration.policy.apply_managed", PolicyApplyManagedParams, "Internal: an SSO-provisioned or MDM-managed policy replaces and locks the team policy."),
  internal("integration.policy.release_managed", Schema.Struct({ requested_by: Schema.String.check(Schema.isMaxLength(200)) }), "Internal: a team admin released the SSO or MDM lock (TeamDO team.integration.release_lock); the values stay, unlocked."),
  internal("integration.policy.lock_acked", Schema.Struct({ version: Schema.Number.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1)) }), "Internal: TeamDO recorded this lock change.")
]
