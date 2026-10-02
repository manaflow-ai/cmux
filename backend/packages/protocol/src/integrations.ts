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

export const IntegrationProvider = Schema.Literals(["github", "linear", "slack"]).annotate({ identifier: "IntegrationProvider" })
export type IntegrationProvider = typeof IntegrationProvider.Type

export const ConnectionStatus = Schema.Literals(["pending", "active", "needs_reauth", "error", "revoked"]).annotate({ identifier: "ConnectionStatus" })

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
  created_at: Schema.Int,
  updated_at: Schema.Int
}).annotate({ identifier: "Connection" })
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
  errors: [...mutationErrors, "integration.not_configured", "integration.limit"],
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
    errors: [...mutationErrors, "selector.not_found", "integration.unavailable", "provider.error", "mutation.indeterminate"],
    docs,
    cli: { path: name.replace(/\./g, " "), visible: true },
    mcp: { expose: "default", group: name.split(".")[0]! }
  })

const Text = (max: number) => Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(max))

export const GitHubIssueComment = providerOp(
  "github.issue.comment",
  "send-external",
  Schema.Struct({ connection: ConnectionId, repo: Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/)), issue: Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 1e9 })), body: Text(65_000) }),
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

export const integrationOps = [IntegrationConnect, IntegrationComplete, IntegrationRevoke, IntegrationList, GitHubIssueComment, LinearIssueCreate, SlackPostAsBot] as const
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
  scopes_granted: Schema.Array(Schema.String)
})
export const ConnectionStatusParams = Schema.Struct({
  connection: ConnectionId,
  status: Schema.Literals(["active", "needs_reauth", "error"]),
  detail: Schema.optionalKey(Schema.String.check(Schema.isMaxLength(300)))
})

/** Ops only the ConnectionDO submits for itself (after an external effect). Not exported to the catalog. */
export const connectionInternalOps: ReadonlyArray<CloudOpDef> = [
  internal("connection.activate", ConnectionActivateParams, "Internal: the provider approved; the credential is stored."),
  internal("connection.status", ConnectionStatusParams, "Internal: a refresh, call or provider event changed the connection's health.")
]
