import { Schema } from "effect"
import { isPattern } from "./json-checks.ts"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { DisplayName, HostId, InstallId, PairingCode, Platform, PublicJwk, ServerCapabilities, TeamId, UserId } from "./schemas.ts"
import { NativeDeviceId, NativeMeshId, ServerNetworkBinding, ServerNetworkProof, ServerNetworkReservation } from "./server-network.ts"

/**
 * cmux server pairing (plans/cmux-next/server.md 6). A server that has no
 * account calls `POST /v1/pair/begin` (unauthenticated, rate-limited, proof of
 * possession of its install key) and waits on a WebSocket to its PairingDO. A
 * signed-in user previews and approves the code; approval registers the
 * server's install key under the approver and adds the host to the team
 * directory (TeamDO's internal `server.enrolled`, reached only through the
 * approve route). Approval and revocation are user-origin only: never an install
 * token, never an agent, never MCP.
 */

export const PairingInfo = Schema.Struct({
  name: DisplayName,
  platform: Platform,
  os_version: Schema.String.check(Schema.isMaxLength(80)),
  arch: Schema.Literals(["x86_64", "aarch64"]),
  cmux_version: Schema.String.check(Schema.isMaxLength(40)),
  /** What the server is, for the approver (`optchat-chief-brain`); kept on the paired install. */
  capabilities: Schema.optionalKey(ServerCapabilities)
}).annotate({ identifier: "PairingInfo" })

export const PairingPreview = Schema.Struct({
  code: PairingCode,
  info: PairingInfo,
  public_jwk: PublicJwk,
  /** RFC 7638 SHA-256 thumbprint of `public_jwk` (base64url); clients derive the four check words from it. */
  thumbprint: Schema.String,
  /** Country of the begin request, as Cloudflare reported it, or null. */
  country: Schema.NullOr(Schema.String),
  expires_at: Schema.Int
}).annotate({ identifier: "PairingPreview" })

export const ServerPairPreview = def({
  name: "server.pair.preview",
  owner: "cloud:PairingDO",
  class: "read",
  risk: "read",
  target: "pairing",
  principals: ["session"],
  params: Schema.Struct({ code: PairingCode }),
  result: PairingPreview,
  errors: ["auth.unauthenticated", "selector.not_found", "validation.invalid"],
  docs: "Show what a pending pairing code would add: the server's name, platform, key thumbprint and location.",
  cli: { path: "servers preview", visible: true },
  mcp: { expose: "never", group: "servers" }
})

export const ServerPairApprove = def({
  name: "server.pair.approve",
  owner: "cloud:PairingDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "pairing",
  principals: ["session"],
  params: Schema.Struct({ code: PairingCode, team: TeamId, name: DisplayName, mesh: Schema.optionalKey(NativeMeshId) }),
  result: Schema.Struct({ host: HostId, team: TeamId, user: UserId, install: InstallId, network: Schema.optionalKey(ServerNetworkReservation) }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Approve a pairing code and register its install and host. With a Native mesh, pin the network request and deliver a short-lived key-bound enrollment code only to the waiting server. The result contains public network ids; pairing does not activate a role or grant execution.",
  cli: { path: "servers add", visible: true },
  mcp: { expose: "never", group: "servers" }
})

/** Invite code: 10 Crockford base32 symbols (50 bits), shown as XXXXX-XXXXX. Never the length of a PairingCode. */
export const PairingInviteCode = Schema.String.check(isPattern(/^[0-9A-HJKMNP-TV-Z]{10}$/)).annotate({
  identifier: "PairingInviteCode",
  description: "A normalized invite code: 10 Crockford base32 symbols, no hyphen."
})

export const PairingInvite = Schema.Struct({
  invite: PairingInviteCode,
  /** `ABCDE-12345`, for a person to read or type. */
  display: Schema.String,
  expires_at: Schema.Int,
  /** Opens `GET /v1/pair/invite/wait?invite=CODE` (subprotocols `cmux.pair-invite.v1, watch.<secret>`). Never shown or logged. */
  watch_secret: Schema.String
}).annotate({ identifier: "PairingInvite" })

export const ServerPairInvite = def({
  name: "server.pair.invite",
  owner: "cloud:PairingDO",
  class: "mutation",
  risk: "mutate-shared",
  target: "pairing",
  principals: ["session"],
  params: Schema.Struct({ team: TeamId }),
  result: PairingInvite,
  errors: [...mutationErrors, "owner.unreachable"],
  docs: "Make a 10-minute, single-use invite code that a new machine types (`cmux pair CODE`) to ask to join the team. Only the person who made it can approve that machine, after comparing its four words; making another invite voids this one. Origin user only.",
  cli: { path: "servers invite", visible: false },
  mcp: { expose: "never", group: "servers" }
})

export const ServerRevoke = def({
  name: "server.revoke",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "destructive",
  target: "host",
  principals: ["session"],
  params: Schema.Struct({ host: HostId }),
  result: Schema.Struct({ host: HostId, install_revoked: Schema.Boolean }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Remove a server from the team directory and revoke its install key (the owner; a team admin removes it from the directory).",
  cli: { path: "servers revoke", visible: true },
  mcp: { expose: "never", group: "servers" }
})

export const ServerNetworkConfirm = def({
  name: "server.network.confirm",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "host",
  principals: ["install"],
  params: Schema.Struct({ host: HostId, mesh: NativeMeshId, device: NativeDeviceId, proof: ServerNetworkProof }),
  result: Schema.Struct({ host: HostId, network: ServerNetworkBinding }),
  errors: [...mutationErrors, "selector.not_found", "owner.unreachable"],
  docs: "The paired daemon confirms its approved network reservation with a fresh signed policy read. Tenant, device and public keys must match the current owners. This records identity only; it does not activate transport or serving roles.",
  cli: { path: "servers network confirm", visible: false },
  mcp: { expose: "never", group: "servers" }
})

export const serverOps = [ServerPairPreview, ServerPairApprove, ServerPairInvite, ServerNetworkConfirm, ServerRevoke] as const satisfies readonly CloudOpDef[]
