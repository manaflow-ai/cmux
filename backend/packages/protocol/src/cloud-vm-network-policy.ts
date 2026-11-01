import { Schema } from "effect"
import { isPattern } from "./json-checks.ts"
import { MachineId } from "./cloud-machine-ops.ts"
import { HostId, InstallId, TeamId, UserId, WgPublicKey } from "./schemas.ts"
import { NativeDeviceId, NativeMeshId, NativeTenantId } from "./server-network.ts"

const Version = Schema.String.check(isPattern(/^[0-9a-f]{64}$/))
const Point = Schema.String.check(isPattern(/^B[A-Za-z0-9+/]{86}=$/))
export const NativeVmId = Schema.String.check(isPattern(/^vm_[0-9a-hjkmnp-tv-z]{26}$/))
export const CloudVmReceiverPeer = Schema.Struct({
  host: HostId, user: UserId, install: InstallId, device: NativeDeviceId, wg_public_key: WgPublicKey, install_public_key: Point,
  authority_version: Version, services: Schema.Array(Schema.Literals(["daemon", "ssh"])).check(Schema.isMinLength(1), Schema.isMaxLength(2))
}).annotate({ identifier: "CloudVmReceiverPeer" })
export const CloudVmNetworkPolicyView = Schema.Struct({
  schema_version: Schema.Literal(2), machine: MachineId, host: HostId, epoch: Schema.Int.check(Schema.isGreaterThanOrEqualTo(1)),
  receiver_generation: Schema.NullOr(Version),
  user: UserId, install: InstallId, team: TeamId, origin: Schema.String, tenant: NativeTenantId, mesh: NativeMeshId, vm: NativeVmId,
  ipv4: Schema.NullOr(Schema.String), wg_public_key: WgPublicKey, install_public_key: Point,
  authority_version: Version, checked_at: Schema.Int, expires_at: Schema.Int,
  acl_version: Schema.Int.check(Schema.isGreaterThanOrEqualTo(0)), policy_digest: Version,
  peers: Schema.Array(CloudVmReceiverPeer).check(Schema.isMaxLength(128))
}).annotate({ identifier: "CloudVmNetworkPolicyView" })
