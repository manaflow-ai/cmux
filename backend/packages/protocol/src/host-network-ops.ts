import { Schema } from "effect"
import { def, mutationErrors, type CloudOpDef } from "./op-def.ts"
import { HostId, WgPublicKey } from "./schemas.ts"
import { NativeDeviceId, NativeMeshId, ServerNetworkBinding, ServerNetworkProof } from "./server-network.ts"

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

export const hostNetworkOps = [HostNetworkBind] as const satisfies readonly CloudOpDef[]
