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
  /** lost: TeamDO thought the team owned the domain, but DomainDO refused it on a re-check. */
  state: Schema.Literals(["pending", "verified", "lost"]),
  /** The TXT record to publish: name and value. */
  record_name: Schema.String,
  record_value: Schema.String,
  requested_at: Schema.Int,
  /** A pending claim expires; claiming again issues a new value. */
  expires_at: Schema.Int,
  verified_at: Schema.NullOr(Schema.Int)
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

export const ssoOps = [DomainClaim, DomainVerify, DomainRelease, DomainList] as const
