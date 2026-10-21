import { createCmuxVmClient } from "@cmux/vm"
import type { VmApiSettings } from "./cloud-vm-api-config.ts"
import { DriverError } from "./team-vm-driver.ts"

export const teamApiFailure = (message: string, final = false) => new DriverError("team_vm.provider_failed", `VM API: ${message}`, final)
export const TEAM_API_VM_ID = /^vm_[0-9a-hjkmnp-tv-z]{26}$/

/** Bounded, sanitized requests. A hidden allocation and a physically missing VM are different. */
export class TeamVmApiRequest {
  readonly client
  constructor(settings: VmApiSettings, tenant: string, fetchFn: typeof fetch = fetch) {
    this.client = createCmuxVmClient({ token: settings.key, teamId: tenant, baseUrl: settings.origin, fetch: (request) =>
      fetchFn(new Request(request, { redirect: "manual", signal: AbortSignal.any([request.signal, AbortSignal.timeout(request.method === "POST" && new URL(request.url).pathname === "/v1/vms" ? 120_000 : 30_000)]) })) })
  }
  async request<R>(work: () => Promise<R>): Promise<R> {
    try { return await work() } catch { throw teamApiFailure("no readable answer") }
  }
  value<T>(r: { response: Response; data?: T }, status = 200): T {
    if (r.response.status !== status || r.data === undefined) throw teamApiFailure(`HTTP ${r.response.status}`, r.response.status >= 400 && r.response.status < 500 && r.response.status !== 429)
    return r.data
  }
  async presence(id: string): Promise<"present" | "missing"> {
    const r = this.value(await this.request(() => this.client.GET("/v1/vms/{vmId}/identity", { params: { path: { vmId: id }, query: { checkPresence: "true" } } })))
    if (r.id !== id || r.scheme !== "sha256-v1" || !/^[0-9a-f]{64}$/.test(r.fingerprint) || (r.presence !== "present" && r.presence !== "missing")) throw teamApiFailure("unconfirmed VM presence")
    return r.presence
  }
  /** Raw 404 never permits the owner to spend on a replacement. */
  async missing(id: string): Promise<never> {
    if (await this.presence(id) === "missing") throw new DriverError("team_vm.vm_missing", "the owned VM is physically missing", true)
    throw teamApiFailure("the VM operation could not be confirmed")
  }
}
