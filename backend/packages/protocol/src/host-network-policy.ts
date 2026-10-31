import { Schema } from "effect"
import { def } from "./op-def.ts"
import { HostId, InstallId, TeamId, UserId, WgPublicKey } from "./schemas.ts"
import { NativeDeviceId, NativeMeshId, NativeTenantId, ServerNetworkProof } from "./server-network.ts"

const Version = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/))
const Point = Schema.String.check(Schema.isPattern(/^B[A-Za-z0-9+/]{86}=$/))
const Port = Schema.Int.check(Schema.isBetween({ minimum: 1, maximum: 65535 }))
export const NetworkAllow = Schema.Union([
  Schema.Struct({ protocol: Schema.Literals(["tcp", "udp"]), port: Schema.optionalKey(Port) }),
  Schema.Struct({ protocol: Schema.Literals(["any", "icmp"]) })
])
export const HostNetworkPeer = Schema.Struct({
  host: HostId, user: UserId, install: InstallId, device: NativeDeviceId, wg_public_key: WgPublicKey, install_public_key: Point,
  authority_version: Version, inbound: Schema.Array(NetworkAllow).check(Schema.isMaxLength(4096)), outbound: Schema.Array(NetworkAllow).check(Schema.isMaxLength(4096))
}).annotate({ identifier: "HostNetworkPeer" })
export const HostNetworkPolicyView = Schema.Struct({
  schema_version: Schema.Literal(1), host: HostId, user: UserId, install: InstallId, team: TeamId, origin: Schema.String, tenant: NativeTenantId, mesh: NativeMeshId, device: NativeDeviceId,
  wg_public_key: WgPublicKey, install_public_key: Point, authority_version: Version, checked_at: Schema.Int, expires_at: Schema.Int,
  acl_version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)), policy_digest: Version,
  peers: Schema.Array(HostNetworkPeer).check(Schema.isMaxLength(128))
}).annotate({ identifier: "HostNetworkPolicyView" })

export const HostNetworkPolicy = def({
  name: "host.network.policy", owner: "cloud:TeamDO", class: "read", risk: "read", target: "host", principals: ["install"],
  params: Schema.Struct({ host: HostId, proof: ServerNetworkProof }), result: HostNetworkPolicyView,
  errors: ["validation.invalid", "auth.unauthenticated", "auth.forbidden", "owner.unreachable"],
  docs: "Read the calling host's current directed Native peer policy with a fresh install-key proof. Peers are joined to live backend hosts, owners, installs and original grants; unmatched peers grant no access. This bounded identity snapshot is not a dial credential or a serving-role activation. Receivers still need current authority and service authentication.",
  cli: { path: "host network policy", visible: false }, mcp: { expose: "never", group: "team" }
})
