import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { HostId, TeamId, WgPublicKey } from "./schemas.ts"
import { NativeDeviceId, NativeMeshId, NativeTenantId, ServerNetworkBinding, ServerNetworkProof } from "./server-network.ts"

export const HostNetworkTarget = def({
  name: "host.network.target",
  owner: "cloud:TeamDO",
  class: "read",
  risk: "read",
  target: "team",
  principals: ["install"],
  params: Schema.Struct({ mesh: Schema.optionalKey(NativeMeshId) }),
  result: Schema.Struct({ team: TeamId, tenant: NativeTenantId, project: Schema.String, origin: Schema.String, mesh: NativeMeshId, ipv4_cidr: Schema.String }),
  errors: ["validation.invalid", "auth.unauthenticated", "auth.forbidden", "selector.not_found", "owner.unreachable"],
  docs: "Discover the configured Native origin and canonical team tenant for an active client install with read and mutate-own grants. Verify the requested mesh or select the tenant's sole mesh. This read creates no tenant, mesh, device or serving grant and returns no service credential.",
  cli: { path: "host network target", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const HostNetworkBind = def({
  name: "host.network.bind",
  owner: "cloud:TeamDO",
  class: "mutation",
  risk: "mutate-own",
  target: "host",
  principals: ["install"],
  params: Schema.Struct({ host: HostId, mesh: NativeMeshId, device: NativeDeviceId, wg_public_key: WgPublicKey, proof: ServerNetworkProof }),
  result: Schema.Struct({ host: HostId, network: ServerNetworkBinding }),
  errors: [...mutationErrors, "selector.not_found", "owner.unreachable"],
  docs: "Bind the calling client install's own host to a network device using a fresh policy read signed by that install key. Verify the authoritative team tenant and both public keys. This records identity only; current transport policy and serving permissions remain separate.",
  cli: { path: "host network bind", visible: false },
  mcp: { expose: "never", group: "team" }
})

export const hostNetworkOps = [HostNetworkTarget, HostNetworkBind] as const satisfies readonly CloudOpDef[]
