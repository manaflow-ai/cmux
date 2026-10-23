import { GrantId, HostId, InstallId, NativeDeviceId, NativeMeshId, NativeTenantId, UserId, WgPublicKey } from "@cmux/protocol"
import { Schema } from "effect"

export const HostNetworkBoundParams = Schema.Struct({
  host: HostId, install: InstallId, owner_user: UserId, grant: Schema.optionalKey(GrantId), wg_public_key: WgPublicKey,
  network: Schema.Struct({ tenant: NativeTenantId, mesh: NativeMeshId, device: NativeDeviceId })
})
