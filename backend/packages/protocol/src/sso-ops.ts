import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { TeamId } from "./schemas.ts"

/**
 * Enterprise SSO, slice 2c-1: email domain ownership (spec/enterprise.md 3.4).
 * A team claims a domain, publishes a DNS TXT record, and verifies it; the
 * domain's DomainDO is the single writer of which team owns it. Verified
 * domains route sign-in to the team's SSO connection (slice 2c-2) and enable
 * enforced SSO (slice 2c-3).
 */
export const EmailDomain = Schema.String.check(
  Schema.isMaxLength(253),
  Schema.isPattern(/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/)
).annotate({ identifier: "EmailDomain", description: "A lowercase DNS name such as acme.com." })

export const TeamDomain = Schema.Struct({
  domain: EmailDomain,
  /**
   * lost: DomainDO refused a re-check (another team owns it). lapsed: the weekly
   * DNS re-check failed three times; discovery stops and DomainDO frees the
   * domain, but nobody is unlinked; verifying again restores it.
   */
  state: Schema.Literals(["pending", "verified", "lost", "lapsed"]),
  /** The TXT record to publish: name and value. */
  record_name: Schema.String,
  record_value: Schema.String,
  requested_at: Schema.Int,
  /** A pending claim expires; claiming again issues a new value. */
  expires_at: Schema.Int,
  verified_at: Schema.NullOr(Schema.Int),
  /** Weekly re-check of a verified domain (spec 3.4). */
  last_checked_at: Schema.optionalKey(Schema.Int),
  check_failures: Schema.optionalKey(Schema.Int)
}).annotate({ identifier: "TeamDomain" })

export const DomainClaim = def({
  name: "domain.claim",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ domain: EmailDomain }),
  result: TeamDomain,
  errors: [...mutationErrors, "policy.invalid"],
  docs: "Start verifying an email domain for the team (owners and admins): returns the DNS TXT record to publish. Public mail domains are refused.",
  cli: { path: "team domain claim", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DomainVerify = def({
  name: "domain.verify",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ domain: EmailDomain }),
  result: TeamDomain,
  errors: [...mutationErrors, "selector.not_found", "domain.not_verified", "domain.taken"],
  docs: "Check the TXT record through two DNS-over-HTTPS resolvers and, when both see it, make the team the domain's owner (owners and admins).",
  cli: { path: "team domain verify", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DomainRelease = def({
  name: "domain.release",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ domain: EmailDomain }),
  result: Schema.Struct({ domain: EmailDomain }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Give up a claimed or verified domain (owners and admins). Another team may then verify it.",
  cli: { path: "team domain release", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DomainList = def({
  name: "domain.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session", "install"],
  params: Schema.Struct({}),
  result: Schema.Struct({ team: TeamId, domains: Schema.Array(TeamDomain), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The team's claimed and verified email domains (owners and admins).",
  cli: { path: "team domain list", visible: true },
  mcp: { expose: "never", group: "team" }
})

const ConnectionId = Schema.String.check(Schema.isPattern(/^ssoc_[a-z0-9]{20}$/)).annotate({ identifier: "SsoConnectionId" })
const HttpsUrl = Schema.String.check(Schema.isMaxLength(500), Schema.isPattern(/^https:\/\/[^\s]+$/))

/**
 * An enterprise SSO connection (spec/enterprise.md 3.2, WorkOS-shaped).
 * Slice 2c-2: OIDC. The client secret is never part of this record, an op's
 * params, an event or a snapshot: sso.connection.set_secret seals it into a
 * TeamDO side table and only `secret_set` is visible.
 */
export const SsoConnection = Schema.Struct({
  id: ConnectionId,
  kind: Schema.Literal("oidc"),
  state: Schema.Literals(["draft", "active", "disabled"]),
  /** Verified domains of the team this connection serves (sign-in discovery). */
  domains: Schema.Array(EmailDomain),
  oidc: Schema.Struct({
    issuer: HttpsUrl,
    client_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
    scopes: Schema.Array(Schema.String.check(Schema.isMaxLength(64))),
    /** From the issuer's discovery document, filled at activation. */
    authorization_endpoint: Schema.NullOr(HttpsUrl),
    token_endpoint: Schema.NullOr(HttpsUrl),
    jwks_uri: Schema.NullOr(HttpsUrl)
  }),
  secret_set: Schema.Boolean,
  jit: Schema.Struct({ enabled: Schema.Boolean, default_role: Schema.Literals(["member", "admin"]) }),
  created_at: Schema.Int,
  updated_at: Schema.Int
}).annotate({ identifier: "SsoConnection" })

export const SsoConnectionCreate = def({
  name: "sso.connection.create",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    issuer: HttpsUrl,
    client_id: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(200)),
    domains: Schema.Array(EmailDomain).check(Schema.isMinLength(1), Schema.isMaxLength(20)),
    scopes: Schema.optionalKey(Schema.Array(Schema.String.check(Schema.isMaxLength(64))).check(Schema.isMaxLength(20))),
    jit: Schema.optionalKey(Schema.Struct({ enabled: Schema.Boolean, default_role: Schema.Literals(["member", "admin"]) }))
  }),
  result: SsoConnection,
  errors: [...mutationErrors, "policy.invalid"],
  docs: "Create an OIDC connection in draft (owners and admins). Then set its client secret and activate it.",
  cli: { path: "team sso create", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const SsoConnectionSetSecret = def({
  name: "sso.connection.set_secret",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ connection: ConnectionId, client_secret: Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(4096)) }),
  result: SsoConnection,
  errors: [...mutationErrors, "selector.not_found", "sso.not_configured"],
  docs: "Seal the OIDC client secret (owners and admins). The secret is never returned, logged or recorded in events.",
  cli: { path: "team sso set-secret", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const SsoConnectionActivate = def({
  name: "sso.connection.activate",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ connection: ConnectionId }),
  result: SsoConnection,
  errors: [...mutationErrors, "selector.not_found", "policy.invalid", "sso.discovery_failed"],
  docs: "Fetch the issuer's OpenID discovery document and activate the connection (owners and admins). Needs the secret and every domain verified by this team.",
  cli: { path: "team sso activate", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const SsoConnectionDisable = def({
  name: "sso.connection.disable",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ connection: ConnectionId }),
  result: SsoConnection,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Disable a connection (owners and admins): sign-in discovery stops routing to it.",
  cli: { path: "team sso disable", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const SsoConnectionList = def({
  name: "sso.connection.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({}),
  result: Schema.Struct({ team: TeamId, connections: Schema.Array(SsoConnection), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The team's SSO connections, without secrets (owners and admins).",
  cli: { path: "team sso list", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const ssoOps = [DomainClaim, DomainVerify, DomainRelease, DomainList, SsoConnectionCreate, SsoConnectionSetSecret, SsoConnectionActivate, SsoConnectionDisable, SsoConnectionList] as const
