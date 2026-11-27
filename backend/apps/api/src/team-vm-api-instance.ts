import { createCmuxVmClient } from "@cmux/vm"
import { INSTANCE_IDENTITY_SCHEME, instanceFingerprint } from "../../../../libs/vm-instance-identity/src/identity.ts"
import type { VmApiSettings } from "./cloud-vm-api-config.ts"
import { DriverError } from "./team-vm-driver.ts"

/** Only the configured tenant VM API can supply the expected allocation identity. */
export const vmApiInstanceMatches = (settings: VmApiSettings, tenant: string, fetchFn: typeof fetch = fetch) => {
  const client = createCmuxVmClient({ token: settings.key, teamId: tenant, baseUrl: settings.origin, fetch: (request) => fetchFn(new Request(request, { redirect: "manual", signal: AbortSignal.timeout(20_000) })) })
  return async (vm: string, signedInstance: string): Promise<boolean> => {
    if (!/^vm_[0-9a-hjkmnp-tv-z]{26}$/.test(vm) || !/^[A-Za-z0-9_-]{1,128}$/.test(signedInstance)) return false
    let result
    try { result = await client.GET("/v1/vms/{vmId}/identity", { params: { path: { vmId: vm } } }) }
    catch { throw new DriverError("team_vm.provider_failed", "the VM instance identity could not be confirmed", false) }
    if (result.response.status === 404) return false
    if (result.response.status !== 200 || !result.data) throw new DriverError("team_vm.provider_failed", "the VM instance identity could not be confirmed", false)
    const receipt = result.data
    return receipt.id === vm && receipt.scheme === INSTANCE_IDENTITY_SCHEME && /^[0-9a-f]{64}$/.test(receipt.fingerprint) && receipt.fingerprint === await instanceFingerprint(signedInstance)
  }
}
