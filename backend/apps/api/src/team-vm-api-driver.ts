import { recoverTeamVmCreation } from "./team-vm-api-creation.ts";
import type { Vm } from "@cmux/vm"
import type { VmApiSettings } from "./cloud-vm-api-config.ts"
import { sha256Hex } from "./cloud-link.ts"
import type { ProviderState } from "./domains/team-vm.ts"
import { parseTeamVmCreateSpec } from "./team-vm-api-config.ts"
import { TeamVmApiFiles } from "./team-vm-api-files.ts"
import { vmApiInstanceMatches } from "./team-vm-api-instance.ts"
import { TeamVmApiRequest, teamApiFailure, TEAM_API_VM_ID } from "./team-vm-api-request.ts"
import type { TeamVmDriver } from "./team-vm-driver.ts"
import type { LedgerRow, TeamVmLedger } from "./team-vm-ledger.ts"

/** One exact owner-ledger allocation, accessed with the dedicated Team VM service credential. */
export class VmApiTeamDriver implements TeamVmDriver {
  private readonly api: TeamVmApiRequest
  readonly files: TeamVmApiFiles
  readonly instanceMatches
  constructor(private readonly settings: VmApiSettings, private readonly tenant: string, private readonly row: LedgerRow,
    private readonly ledger: TeamVmLedger, private readonly mayCreate: () => boolean, fetchFn: typeof fetch = fetch) {
    this.api = new TeamVmApiRequest(settings, tenant, fetchFn)
    this.files = new TeamVmApiFiles(this.api)
    this.instanceMatches = vmApiInstanceMatches(settings, tenant, fetchFn)
  }
  private labels() { return { role: "team-vm", cmux_next_team: this.row.team, cmux_next_epoch: String(this.row.epoch), "cmux/name": this.row.name } }
  private checked(vm: Vm, id?: string): Vm {
    if (!TEAM_API_VM_ID.test(vm?.id) || (id !== undefined && vm.id !== id) || vm.displayName !== this.row.name ||
      !Object.entries(this.labels()).every(([k, v]) => vm.labels?.[k] === v)) throw teamApiFailure("unconfirmed Team VM ownership", true)
    if (!["starting", "running", "pausing", "paused", "stopped"].includes(vm.state)) throw teamApiFailure("invalid VM state")
    return vm
  }
  private async vm(id: string): Promise<Vm> {
    const r = await this.api.request(() => this.api.client.GET("/v1/vms/{vmId}", { params: { path: { vmId: id } } }))
    if (r.response.status === 404) return this.api.missing(id)
    return this.checked(this.api.value(r), id)
  }
  private async discover(): Promise<Vm | null> {
    let cursor: string | undefined, found: Vm | null = null
    const seen = new Set<string>()
    for (let page = 0; page < 512; page++) {
      const data = this.api.value(await this.api.request(() => this.api.client.GET("/v1/vms", { params: { query: { createdBy: "caller", limit: "100",
        label: Object.entries(this.labels()).map(([k, v]) => `${k}=${v}`), ...(cursor ? { cursor } : {}) } } })))
      if (!Array.isArray(data.items)) throw teamApiFailure("invalid VM discovery")
      for (const vm of data.items) {
        if (found) throw teamApiFailure("ambiguous Team VM allocation", true)
        found = this.checked(vm)
      }
      if (data.nextCursor === null) return found
      if (typeof data.nextCursor !== "string" || seen.has(data.nextCursor)) throw teamApiFailure("invalid VM cursor")
      seen.add(data.nextCursor); cursor = data.nextCursor
    }
    throw teamApiFailure("VM discovery page limit")
  }
  async lookup(name: string) {
    if (name !== this.row.name) throw teamApiFailure("wrong allocation name", true)
    if (this.row.provider_id) { const vm = await this.vm(this.row.provider_id); return { id: vm.id, team: this.row.team } }
    if (await this.discover()) throw teamApiFailure("create receipt is still unconfirmed")
    return null
  }
  async ensureVm(name: string, team: string, epoch: number) {
    if (name !== this.row.name || team !== this.row.team || epoch !== this.row.epoch) throw teamApiFailure("wrong create intent", true)
    if (this.row.provider_id) { const vm = await this.vm(this.row.provider_id); return { id: vm.id, state: vm.state as ProviderState } }
    const spec = parseTeamVmCreateSpec(this.ledger.apiCreate(name)?.api_spec ?? null)
    if (!spec) throw teamApiFailure("missing pinned image intent", true)
    const sent = this.ledger.apiCreate(name)
    if (sent?.api_sent_key && sent.api_sent_at !== null) {
      const recovered = await recoverTeamVmCreation(this.api, name, this.labels(), spec, true)
      if (recovered !== null) {
        const vm = await this.vm(recovered)
        this.ledger.confirm(name, vm.id)
        return { id: vm.id, state: vm.state as ProviderState }
      }
    }
    const candidate = await this.discover()
    if (candidate && !this.ledger.apiCreate(name)?.api_sent_key) throw teamApiFailure("an allocation exists without this owner's create receipt", true)
    const context = await sha256Hex(JSON.stringify([this.settings.origin, this.tenant, this.settings.key]))
    if (!this.mayCreate()) throw teamApiFailure("the create no longer has an active wake lease", true)
    if (!this.ledger.claimApiSend(name, context, Date.now())) throw teamApiFailure("uncertain create requires its original context and recovery window", true)
    // Replay only the original body and key inside API retention. A list answer cannot prove image/network setup.
    const vm = this.api.value(await this.api.request(() => this.api.client.POST("/v1/vms", { params: { header: { "idempotency-key": `team-vm-create:${name}` } },
      body: { displayName: name, labels: this.labels(), image: spec.image, idleTimeoutSeconds: spec.idleTimeoutSeconds, initialNetwork: { publicEgress: true } } })), 201)
    this.checked(vm)
    if ((candidate && candidate.id !== vm.id) || vm.idleTimeoutSeconds !== spec.idleTimeoutSeconds || vm.bootImage?.id !== spec.image.id || vm.bootImage.revision !== spec.image.revision ||
      vm.initialNetwork?.publicEgress !== true || vm.initialNetwork.httpsProxyHosts.length !== 0) throw teamApiFailure("unconfirmed create receipt")
    this.ledger.confirm(name, vm.id)
    return { id: vm.id, state: vm.state as ProviderState }
  }
  async ensureRunning(id: string) {
    const seen = await this.vm(id)
    if (seen.state === "running" || seen.state === "starting") return { state: seen.state }
    const r = await this.api.request(() => this.api.client.POST("/v1/vms/{vmId}/start", { params: { path: { vmId: id } } }))
    if (r.response.status === 404) return this.api.missing(id)
    return { state: this.checked(this.api.value(r), id).state as ProviderState }
  }
  async retireVm(id: string) {
    const r = await this.api.request(() => this.api.client.POST("/v1/vms/{vmId}/retire", { params: { path: { vmId: id } } }))
    if (r.response.status === 404) return this.api.missing(id)
    const receipt = this.api.value(r)
    if (receipt.id !== id || receipt.retired !== true || (receipt.state !== "paused" && receipt.state !== "stopped")) throw teamApiFailure("unconfirmed retirement")
  }
  async deleteVm(id: string) {
    const r = await this.api.request(() => this.api.client.DELETE("/v1/vms/{vmId}", { params: { path: { vmId: id } } }))
    // An inaccessible allocation is also 404. Keep its ledger row until deletion is confirmed.
    if (r.response.status !== 204) throw teamApiFailure(`delete HTTP ${r.response.status}`)
  }
  async exec(id: string, command: string, timeoutMs: number) {
    const r = await this.api.request(() => this.api.client.POST("/v1/vms/{vmId}/exec", { signal: AbortSignal.timeout(timeoutMs + 5_000), params: { path: { vmId: id } }, body: { command, linuxUser: "root", timeoutMs } }))
    if (r.response.status === 404) return this.api.missing(id)
    const data = this.api.value(r)
    if ((data.exitCode !== null && !Number.isInteger(data.exitCode)) || typeof data.stdout !== "string") throw teamApiFailure("invalid guest answer")
    return { code: data.exitCode ?? -1, stdout: data.stdout.slice(-16_384) }
  }
  async listPage(): ReturnType<TeamVmDriver["listPage"]> { throw teamApiFailure("account-wide reports are unavailable through a tenant credential", true) }
}
