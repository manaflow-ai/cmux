import { Schema } from "effect"
import { def, mutationErrors } from "./op-def.ts"
import { InstallId, TeamId } from "./schemas.ts"

/**
 * Device enrollment (spec/enterprise.md 5.4, decision E3): a team admin makes
 * an enrollment token, an MDM profile carries it (`EnrollmentToken`), and the
 * signed-in app enrolls its install so the team becomes the device's managing
 * team. Only the managing team's device-scoped policy keys apply on a device.
 *
 * The raw token never reaches the server: clients send `token_hash`, the
 * SHA-256 of the token in base64url without padding (43 characters). The
 * creator generates the token and shows it once.
 */
export const TokenHash = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9_-]{43}$/)).annotate({
  identifier: "EnrollmentTokenHash",
  description: "base64url(SHA-256(token)) without padding."
})
export const EnrollmentTokenId = Schema.String.check(Schema.isPattern(/^enr_[a-z0-9]{20}$/)).annotate({ identifier: "EnrollmentTokenId" })
const Domain = Schema.String.check(Schema.isPattern(/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/))
const Label = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))

export const EnrollmentToken = Schema.Struct({
  id: EnrollmentTokenId,
  label: Label,
  /** Only users whose email is in one of these domains may enroll with it; null = any member. */
  allowed_domains: Schema.NullOr(Schema.Array(Domain)),
  expires_at: Schema.NullOr(Schema.Int),
  created_by: Schema.String,
  created_at: Schema.Int,
  revoked_at: Schema.NullOr(Schema.Int),
  uses: Schema.Int
}).annotate({ identifier: "EnrollmentToken" })

export const ManagedDevice = Schema.Struct({
  install: InstallId,
  user: Schema.String,
  via: Schema.Literals(["token", "accept"]),
  token: Schema.NullOr(EnrollmentTokenId),
  at: Schema.Int
}).annotate({ identifier: "ManagedDevice" })

export const EnrollmentTokenCreate = def({
  name: "team.enrollment_token.create",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({
    label: Label,
    token_hash: TokenHash,
    allowed_domains: Schema.optionalKey(Schema.Array(Domain).check(Schema.isMinLength(1), Schema.isMaxLength(50))),
    expires_at: Schema.optionalKey(Schema.Int)
  }),
  result: EnrollmentToken,
  errors: [...mutationErrors, "policy.invalid"],
  docs: "Create a device enrollment token (owners and admins). The caller generates the token, sends only its SHA-256, and shows the token once.",
  cli: { path: "team enrollment-token create", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const EnrollmentTokenRevoke = def({
  name: "team.enrollment_token.revoke",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({ token: EnrollmentTokenId }),
  result: EnrollmentToken,
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Revoke an enrollment token. Devices already enrolled stay managed.",
  cli: { path: "team enrollment-token revoke", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const EnrollmentTokenList = def({
  name: "team.enrollment_token.list",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["session"],
  params: Schema.Struct({}),
  result: Schema.Struct({ team: TeamId, tokens: Schema.Array(EnrollmentToken), devices: Schema.Array(ManagedDevice), revision: Schema.String }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "List enrollment tokens and managed devices (owners and admins).",
  cli: { path: "team enrollment-token list", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DeviceEnroll = def({
  name: "team.device.enroll",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "install",
  principals: ["install"],
  params: Schema.Struct({ token_hash: Schema.optionalKey(TokenHash) }),
  result: ManagedDevice,
  errors: [...mutationErrors, "policy.invalid"],
  docs: "Make this team the calling install's managing team: with an MDM enrollment token's hash, or without one as the user's explicit acceptance.",
  cli: { path: "team device enroll", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DeviceRelease = def({
  name: "team.device.release",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "install",
  principals: ["session", "install"],
  params: Schema.Struct({ install: InstallId }),
  result: Schema.Struct({ install: InstallId }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Stop managing an install (the install's user or a team admin). An MDM profile may enroll it again.",
  cli: { path: "team device release", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const DevicePolicy = def({
  name: "team.device.policy",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "install",
  principals: ["install"],
  params: Schema.Struct({}),
  result: Schema.Struct({
    team: TeamId,
    managed: Schema.Boolean,
    team_name: Schema.String,
    version: Schema.Int,
    /** Device-scoped keys only (cmux.json key paths). Empty when the install is not managed by this team. */
    defaults: Schema.Record(Schema.String, Schema.Unknown),
    enforced: Schema.Record(Schema.String, Schema.Unknown),
    revision: Schema.String
  }),
  errors: ["auth.unauthenticated", "auth.forbidden"],
  docs: "The device-scoped policy for the calling install: values only when this team manages it (decision E3).",
  cli: { path: "team device policy", visible: true },
  mcp: { expose: "never", group: "team" }
})

export const enrollmentOps = [EnrollmentTokenCreate, EnrollmentTokenRevoke, EnrollmentTokenList, DeviceEnroll, DeviceRelease, DevicePolicy] as const
