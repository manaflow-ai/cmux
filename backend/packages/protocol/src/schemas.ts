import { Schema } from "effect"

/** Public prefixed ids (cli.md C7). 20 lowercase hex characters after the prefix. */
const prefixedId = (prefix: string, identifier: string, description: string) =>
  Schema.String.check(Schema.isPattern(new RegExp(`^${prefix}_[a-z0-9]{20}$`))).annotate({ identifier, description })

export const UserId = prefixedId("user", "UserId", "A cmux user (Stack user id kept as an external id).")
export const TeamId = prefixedId("team", "TeamId", "A team; a personal account is a team of one.")
export const DeviceId = prefixedId("dev", "DeviceId", "A device (hardware) that groups installs.")
export const InstallId = prefixedId("inst", "InstallId", "One app, CLI or daemon install with its own keypair.")
export const GrantId = prefixedId("grant", "GrantId", "A server-side grant; tokens carry only its id.")
export const HostId = prefixedId("host", "HostId", "A machine's session host, enrolled by its link.")

export const DisplayName = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(80))
export const IdempotencyKey = Schema.String.check(Schema.isMinLength(1), Schema.isMaxLength(128)).annotate({
  identifier: "IdempotencyKey",
  description: "Client-chosen key; a retry with the same key replays the original result."
})
export const Revision = Schema.String.check(Schema.isPattern(/^[0-9]+$/)).annotate({
  identifier: "Revision",
  description: "Decimal per-object revision (the owner's event sequence)."
})
export const Origin = Schema.Literals(["user", "cli", "mcp", "script", "remote"]).annotate({ identifier: "Origin" })
export const InstallKind = Schema.Literals(["mac", "ios", "cli", "daemon", "web", "vm"]).annotate({ identifier: "InstallKind" })
export const Platform = Schema.Literals(["macos", "ios", "linux", "windows", "web"]).annotate({ identifier: "Platform" })

export const OpClass = Schema.Literals(["read", "mutate-own", "mutate-shared", "execute", "send-external", "money", "destructive"]).annotate({
  identifier: "OpClass"
})

/** ES256 public key as a JWK (P-256). */
export const PublicJwk = Schema.Struct({
  kty: Schema.Literal("EC"),
  crv: Schema.Literal("P-256"),
  x: Schema.String.check(Schema.isMinLength(43), Schema.isMaxLength(43)),
  y: Schema.String.check(Schema.isMinLength(43), Schema.isMaxLength(43))
}).annotate({ identifier: "PublicJwk", description: "ES256 (P-256) public key of an install." })

export const Install = Schema.Struct({
  id: InstallId,
  device: DeviceId,
  kind: InstallKind,
  name: DisplayName,
  device_name: DisplayName,
  platform: Platform,
  public_jwk: PublicJwk,
  thumbprint: Schema.String,
  grant: GrantId,
  created_at: Schema.Int,
  revoked_at: Schema.NullOr(Schema.Int)
}).annotate({ identifier: "Install" })

export const Grant = Schema.Struct({
  id: GrantId,
  grantee: Schema.String,
  op_classes: Schema.Array(OpClass),
  approval: Schema.Literals(["none", "per_call", "per_session"]),
  expires_at: Schema.NullOr(Schema.Int),
  revoked_at: Schema.NullOr(Schema.Int),
  created_from: Schema.Literals(["install", "ui", "automation", "standing_rule"])
}).annotate({ identifier: "Grant" })

export const UserProfile = Schema.Struct({
  id: UserId,
  stack_user_id: Schema.String,
  email: Schema.NullOr(Schema.String),
  /** The identity provider verified `email` (absent on profiles stored before this field). */
  email_verified: Schema.optionalKey(Schema.Boolean),
  display_name: Schema.String,
  personal_team: TeamId
}).annotate({ identifier: "UserProfile" })

export const HostKind = Schema.Literals(["device", "server"]).annotate({ identifier: "HostKind" })
export const WgPublicKey = Schema.String.check(Schema.isPattern(/^[A-Za-z0-9+/]{43}=$/)).annotate({
  identifier: "WgPublicKey",
  description: "A WireGuard public key, standard base64 of 32 bytes."
})
/** Pairing code: 8 Crockford base32 symbols, shown as XXXX-XXXX (plans/cmux-next/server.md 6.2). */
export const PairingCode = Schema.String.check(Schema.isPattern(/^[0-9A-HJKMNP-TV-Z]{8}$/)).annotate({
  identifier: "PairingCode",
  description: "A normalized pairing code: 8 Crockford base32 symbols, no hyphen."
})

export const Host = Schema.Struct({
  id: HostId,
  name: DisplayName,
  platform: Platform,
  owner_user: UserId,
  enrolled_by: InstallId,
  enrolled_at: Schema.Int,
  /** `server` when the owner turned on the server role set (plans/cmux-next/server.md 6); absent means a device. */
  kind: Schema.optionalKey(HostKind),
  /** The host's WireGuard public key (base64, 32 bytes), made on the host and never leaving it. */
  wg_public_key: Schema.optionalKey(WgPublicKey),
  /** Network policy tags, for example `tag:server`. */
  tags: Schema.optionalKey(Schema.Array(Schema.String))
}).annotate({ identifier: "Host" })

export const TeamMember = Schema.Struct({
  user: UserId,
  role: Schema.Literals(["owner", "admin", "member"]),
  display_name: Schema.String
}).annotate({ identifier: "TeamMember" })

/** Errors every cloud op may return (codes shared with cmux-tui's catalog where they exist). */
export const ErrorCode = Schema.Literals([
  "validation.invalid",
  "idempotency.conflict",
  "revision.conflict",
  "selector.not_found",
  "operation.failed",
  "auth.unauthenticated",
  "auth.forbidden",
  "owner.unreachable",
  "mutation.indeterminate",
  "policy.invalid",
  "domain.not_verified",
  "domain.taken",
  "sso.not_configured",
  "sso.discovery_failed"
]).annotate({ identifier: "ErrorCode" })
