import { GrantId, HostId, InstallId, NativeDeviceId, NativeMeshId, NativeTenantId, UserId, WgPublicKey } from "@cmux/protocol"
import { Schema } from "effect"

// `grant`: the install grant the binding was confirmed under (ServerNetworkBinding.install_grant),
// which Native authorization checks live. Optional only so ledger entries written before it decode.
export const HostNetworkBoundParams = Schema.Struct({
  host: HostId, install: InstallId, owner_user: UserId, grant: Schema.optionalKey(GrantId), wg_public_key: WgPublicKey,
  network: Schema.Struct({ tenant: NativeTenantId, mesh: NativeMeshId, device: NativeDeviceId })
})
