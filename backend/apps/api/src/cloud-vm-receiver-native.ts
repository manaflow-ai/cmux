import { NativeDeviceId, NativeMeshId, NativeTenantId, NativeVmId, NetworkAllow, WgPublicKey } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import type { Http } from "./team-domain-external.ts"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { networkBody } from "./network-policy-read.ts"

const Millis = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0))
const Policy = Schema.Struct({
  schemaVersion: Schema.Literal(1), tenantId: NativeTenantId, vmId: NativeVmId, meshId: NativeMeshId,
  ipv4: Schema.NullOr(Schema.String), aclVersion: Millis, checkedAt: Millis, expiresAt: Millis,
  policyDigest: Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/)),
  peers: Schema.Array(Schema.Struct({ deviceId: NativeDeviceId, wgPublicKey: WgPublicKey,
    installPublicKey: Schema.String.check(Schema.isPattern(/^B[A-Za-z0-9+/]{86}=$/)),
    allow: Schema.Array(NetworkAllow).check(Schema.isMaxLength(4096)) })).check(Schema.isMaxLength(128))
})
export type NativeVmReceiverPolicy = typeof Policy.Type

/** Protected service read only. Caller input never selects the origin, tenant or allocation. */
export const readNativeVmReceiverPolicy = async (http: Http, connection: VmApiConnection, tenant: string, mesh: string, vm: string, signal: AbortSignal): Promise<NativeVmReceiverPolicy | null> => {
  const response = await http(new Request(`${connection.origin}/v1/meshes/${mesh}/vms/${vm}/receiver-policy`, {
    method: "GET", redirect: "manual", signal,
    headers: { accept: "application/json", authorization: `Bearer ${connection.key}`, "x-cmux-team-id": tenant }
  }))
  if (response.status !== 200) { await response.body?.cancel(); return null }
  const decoded = Schema.decodeUnknownExit(Policy)(await networkBody(response), { onExcessProperty: "error" })
  if (!Exit.isSuccess(decoded)) return null
  const value = decoded.value, ids = new Set<string>(), keys = new Set<string>(), points = new Set<string>()
  if (![value.aclVersion, value.checkedAt, value.expiresAt].every(Number.isSafeInteger) || value.tenantId !== tenant || value.meshId !== mesh || value.vmId !== vm || value.expiresAt <= value.checkedAt || value.expiresAt - value.checkedAt > 30_000
    || value.peers.reduce((sum, peer) => sum + peer.allow.length, 0) > 4096) return null
  for (const peer of value.peers) {
    if (ids.has(peer.deviceId) || keys.has(peer.wgPublicKey) || points.has(peer.installPublicKey)) return null
    ids.add(peer.deviceId); keys.add(peer.wgPublicKey); points.add(peer.installPublicKey)
  }
  return value
}
