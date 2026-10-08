import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { DisplayName, HostId, InstallId, PairingCode, Platform, PublicJwk, ServerCapabilities, TeamId, UserId } from "./schemas.ts"

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
  params: Schema.Struct({ code: PairingCode, team: TeamId, name: DisplayName }),
  result: Schema.Struct({ host: HostId, team: TeamId, user: UserId, install: InstallId }),
  errors: [...mutationErrors, "selector.not_found"],
  docs: "Approve a pairing code: register the server's install key under you and add the server to the team directory.",
  cli: { path: "servers add", visible: true },
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

export const serverOps = [ServerPairPreview, ServerPairApprove, ServerRevoke] as const satisfies readonly CloudOpDef[]
