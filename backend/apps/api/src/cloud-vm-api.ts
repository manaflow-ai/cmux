import { createCmuxVmClient, type Vm, type components } from "@cmux/vm"
import type { CloudProvider, CreateOptions, EdgeTlsRule, GuestExecResult, ListedVm, VmResources, VmTag } from "./providers/contract.ts"
import type { VmApiSettings } from "./cloud-vm-api-config.ts"
import { sha256Hex } from "./cloud-link.ts"
import { VmApiSnapshotCaptures } from "./cloud-vm-api-snapshot.ts"
import { DriverError } from "./team-vm-driver.ts"

const unavailable = (message: string, final = false) => new DriverError("cloud.provider.unavailable", `VM API: ${message}`, final)
const VM_ID = /^vm_[0-9a-hjkmnp-tv-z]{26}$/
const SNAPSHOT_ID = /^snap_[0-9a-hjkmnp-tv-z]{26}$/
const NAME_LABEL = "cmux/name"
type Snapshot = components["schemas"]["SnapshotSummary"]

/** The generated public API is the only transport here; provider IDs and credentials never enter it. */
export class VmApiCloudDriver implements CloudProvider {
  /** The VM API sizes from the image at create; resize, snapshots, exec and HTTPS proxies it has. */
  readonly capabilities = { sizing: false, resize: true, snapshot: true, guestExec: true, edgeTls: true, clientSession: false }
  private readonly captures: VmApiSnapshotCaptures
  private readonly client
  constructor(private readonly settings: VmApiSettings, tenant: string, private readonly team: string, fetchFn: typeof fetch = fetch) {
    this.client = createCmuxVmClient({ token: settings.key, teamId: tenant, baseUrl: settings.origin, fetch: (request) =>
      fetchFn(new Request(request, { redirect: "manual", signal: AbortSignal.any([request.signal, AbortSignal.timeout(request.url.endsWith("/exec") ? 310_000 : 30_000)]) })) })
    this.captures = new VmApiSnapshotCaptures(this.client, team, (name, expected) => this.findSnapshot(name, expected))
  }

  /** JSON decode, network and abort exceptions must not carry response bodies, stdin or credentials. */
  private async request<R>(work: () => Promise<R>): Promise<R> {
    try { return await work() } catch { throw unavailable("no readable answer") }
  }
  private value<T>(r: { response: Response; data?: T }, status = 200): T {
    if (r.response.status !== status || r.data === undefined) throw unavailable(`HTTP ${r.response.status}`, r.response.status >= 400 && r.response.status < 500 && r.response.status !== 429)
    return r.data
  }
  private empty(r: { response: Response }): void {
    if (r.response.status !== 204 && r.response.status !== 404) throw unavailable(`HTTP ${r.response.status}`, r.response.status >= 400 && r.response.status < 500 && r.response.status !== 429)
  }
  private labels(name: string, machine?: string) {
    return { role: "cloud", cmux_next_team: this.team, [NAME_LABEL]: name, ...(machine ? { cmux_next_machine: machine } : {}) }
  }
  private tag(vm: Vm): Record<string, unknown> {
    if (!VM_ID.test(vm?.id) || vm.labels?.cmux_next_team !== this.team || vm.labels.role !== "cloud") throw unavailable("unconfirmed VM ownership", true)
    return { cmux_next_team: vm.labels.cmux_next_team, cmux_next_machine: vm.labels.cmux_next_machine }
  }
  private async vms(labels: Readonly<Record<string, string>>): Promise<Vm[]> {
    const items: Vm[] = [], seen = new Set<string>()
    let cursor: string | undefined
    for (let page = 0; page < 512; page++) {
      const r = this.value(await this.request(() => this.client.GET("/v1/vms", { params: { query: { createdBy: "caller", limit: "100", label: Object.entries(labels).map(([k, v]) => `${k}=${v}`), ...(cursor ? { cursor } : {}) } } })))
      if (!Array.isArray(r.items)) throw unavailable("invalid VM list")
      for (const vm of r.items) {
        this.tag(vm)
        if (!Object.entries(labels).every(([k, v]) => vm.labels[k] === v)) throw unavailable("unconfirmed VM selector", true)
        items.push(vm)
      }
      if (r.nextCursor === null) return items
      if (typeof r.nextCursor !== "string" || seen.has(r.nextCursor)) throw unavailable("invalid VM cursor")
      seen.add(r.nextCursor); cursor = r.nextCursor
    }
    throw unavailable("VM discovery page limit")
  }
  async find(name: string) {
    const found = await this.vms(this.labels(name))
    if (found.length > 1) throw unavailable("ambiguous VM name", true)
    const vm = found[0]
    return vm ? { id: vm.id, tag: this.tag(vm), state: vm.state } : null
  }
  private proxy(rule: EdgeTlsRule) {
    if (rule.action !== "allow" || rule.destination.port !== 443) throw unavailable("unsupported HTTPS proxy", true)
    return { hostname: rule.domain, destination: `https://${rule.destination.host}`, headers: Object.assign({}, ...rule.transform.map((t) => t.headers)) as Record<string, string> }
  }
  async create(name: string, tag: VmTag, opts: CreateOptions) {
    if (tag.team !== this.team) throw unavailable("wrong Cloud team", true)
    const source = opts.snapshot ? await this.findSnapshot(opts.snapshot) : null
    if (opts.snapshot && !source) throw unavailable("restore snapshot is missing", true)
    const proxies = (opts.edgeRules ?? []).map((rule) => this.proxy(rule))
    const body = { displayName: name, labels: this.labels(name, tag.machine), idleTimeoutSeconds: -1,
      ...(source ? { snapshotId: source.id } : { image: this.settings.image }), initialNetwork: { publicEgress: true, httpsProxies: proxies } }
    const r = this.value(await this.request(() => this.client.POST("/v1/vms", { params: { header: { "idempotency-key": `cloud-create:${name}` } }, body })), 201)
    const actual = this.tag(r)
    if (actual.cmux_next_machine !== tag.machine || r.labels[NAME_LABEL] !== name || r.initialNetwork?.publicEgress !== true ||
      JSON.stringify([...(r.initialNetwork?.httpsProxyHosts ?? [])].sort()) !== JSON.stringify(proxies.map((p) => p.hostname).sort()) ||
      (!source && (r.bootImage?.id !== this.settings.image.id || r.bootImage.revision !== this.settings.image.revision))) throw unavailable("unconfirmed create")
    return { id: r.id, tag: null }
  }
  async delete(id: string): Promise<void> { this.empty(await this.request(() => this.client.DELETE("/v1/vms/{vmId}", { params: { path: { vmId: id } } }))) }
  private async vm(id: string): Promise<Vm | null> {
    const r = await this.request(() => this.client.GET("/v1/vms/{vmId}", { params: { path: { vmId: id } } }))
    if (r.response.status === 404) return null
    const vm = this.value(r)
    if (vm?.id !== id) throw unavailable("wrong VM answer", true)
    if (![vm.resources?.vcpus, vm.resources?.memoryMib, vm.resources?.diskMib].every((n) => Number.isSafeInteger(n) && n > 0)) throw unavailable("invalid VM resources")
    this.tag(vm)
    return vm
  }
  async state(id: string): Promise<string | null> { return (await this.vm(id))?.state ?? null }
  async resources(id: string): Promise<VmResources | null> {
    const vm = await this.vm(id)
    return vm ? { cpu: vm.resources.vcpus, memory: vm.resources.memoryMib, storage: vm.resources.diskMib } : null
  }
  async pause(id: string): Promise<void> {
    const r = this.value(await this.request(() => this.client.POST("/v1/vms/{vmId}/pause", { params: { path: { vmId: id } } })))
    if (r.id !== id) throw unavailable("wrong pause answer")
  }
  async start(id: string): Promise<void> {
    const r = this.value(await this.request(() => this.client.POST("/v1/vms/{vmId}/start", { params: { path: { vmId: id } } })))
    if (r.id !== id) throw unavailable("wrong start answer")
  }
  async findSnapshot(name: string, expected?: { machine?: string; source?: string }): Promise<{ id: string; sourceVmId: string | null } | null> {
    const found: Snapshot[] = [], seen = new Set<string>()
    let cursor: string | undefined
    const labels = this.labels(name, expected?.machine)
    for (let page = 0; page < 512; page++) {
      const r = this.value(await this.request(() => this.client.GET("/v1/snapshots", { params: { query: { createdBy: "caller", limit: "100", labels: Object.entries(labels).map(([k, v]) => `${k}=${v}`).join(","), ...(cursor ? { cursor } : {}) } } })))
      if (!Array.isArray(r.items)) throw unavailable("invalid snapshot list")
      for (const snapshot of r.items) {
        if (!SNAPSHOT_ID.test(snapshot.id) || (expected?.source !== undefined && snapshot.sourceVmId !== expected.source) || !Object.entries(labels).every(([k, v]) => snapshot.labels?.[k] === v)) throw unavailable("unconfirmed snapshot selector", true)
        found.push(snapshot)
      }
      if (found.length > 1) throw unavailable("ambiguous snapshot name", true)
      if (r.nextCursor === null) return found[0] ? { id: found[0].id, sourceVmId: found[0].sourceVmId } : null
      if (typeof r.nextCursor !== "string" || seen.has(r.nextCursor)) throw unavailable("invalid snapshot cursor")
      seen.add(r.nextCursor); cursor = r.nextCursor
    }
    throw unavailable("snapshot discovery page limit")
  }
  async resumeSnapshot(name: string, tag: VmTag, allowSend = true): Promise<{ id: string } | null> {
    return this.captures.resumeFor(tag, name, allowSend)
  }
  async createSnapshot(vmId: string, name: string, tag?: VmTag): Promise<{ id: string }> {
    if (tag && tag.team !== this.team) throw unavailable("wrong Cloud team", true)
    const resumed = await this.captures.resume(name, { source: vmId, ...(tag ? { machine: tag.machine } : {}) }, true)
    if (resumed) return resumed
    const vm = await this.vm(vmId)
    if (!vm) throw unavailable("snapshot source is missing", true)
    if (tag && vm.labels.cmux_next_machine !== tag.machine) throw unavailable("unconfirmed snapshot source", true)
    return this.captures.create(vmId, name, this.labels(name, vm.labels.cmux_next_machine))
  }
  async cancelSnapshot(name: string, tag: VmTag, allowEmptyFence: boolean): Promise<void> { return this.captures.cancel(name, tag, allowEmptyFence) }
  async deleteSnapshot(id: string): Promise<void> { this.empty(await this.request(() => this.client.DELETE("/v1/snapshots/{snapshotId}", { params: { path: { snapshotId: id } } }))) }
  async resize(id: string, size: VmResources): Promise<void> {
    const key = `cloud-resize:${await sha256Hex(JSON.stringify([id, size.cpu, size.memory, size.storage]))}`
    const r = this.value(await this.request(() => this.client.POST("/v1/vms/{vmId}/resize", { params: { path: { vmId: id }, header: { "idempotency-key": key } }, body: { resources: { vcpus: size.cpu, memoryMib: size.memory, diskMib: size.storage } } })))
    if (r.id !== id || !Number.isFinite(r.resources.vcpus) || !Number.isFinite(r.resources.memoryMib) || !Number.isFinite(r.resources.diskMib) || r.resources.vcpus < size.cpu || r.resources.memoryMib < size.memory || r.resources.diskMib < size.storage) throw unavailable("unconfirmed growth")
  }
  async writeFile(id: string, path: string, content: string, mode: number): Promise<void> {
    const r = await this.request(() => this.client.PUT("/v1/vms/{vmId}/files/content", { params: { path: { vmId: id }, query: { path, mode: String(mode) }, header: { "content-length": String(new TextEncoder().encode(content).byteLength) } }, headers: { "content-type": "application/octet-stream" }, body: content, bodySerializer: (body) => body }))
    if (r.response.status !== 204) throw unavailable(`file write HTTP ${r.response.status}`)
  }
  private report: Promise<Vm[]> | undefined
  async list(filter: string, offset: number): Promise<{ vms: ReadonlyArray<ListedVm>; total: number }> {
    if (filter !== `cmux_next_team:${this.team}` || !Number.isInteger(offset) || offset < 0) throw unavailable("invalid report selector", true)
    const vms = await (this.report ??= this.vms({ role: "cloud", cmux_next_team: this.team }))
    return { total: vms.length, vms: vms.slice(offset, offset + 100).map((vm) => ({ id: vm.id, name: vm.labels[NAME_LABEL] ?? null, tag: this.tag(vm) })) }
  }
  async replaceTlsRule(id: string, rule: EdgeTlsRule): Promise<boolean> {
    const proxy = this.proxy(rule)
    const key = `cloud-proxy:${await sha256Hex(JSON.stringify([id, proxy]))}`
    const r = await this.request(() => this.client.PUT("/v1/vms/{vmId}/https-proxies/{hostname}", { params: { path: { vmId: id, hostname: proxy.hostname }, header: { "idempotency-key": key } }, body: { destination: proxy.destination, headers: proxy.headers } }))
    if (r.response.status === 404) return false
    const receipt = this.value(r)
    if (receipt.id !== id || receipt.hostname !== proxy.hostname) throw unavailable("unconfirmed proxy replacement")
    return true
  }
  async execStdin(id: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<GuestExecResult> {
    let encoded = ""
    if (stdin) for (const byte of stdin) encoded += String.fromCharCode(byte)
    const r = this.value(await this.request(() => this.client.POST("/v1/vms/{vmId}/exec", { signal: AbortSignal.timeout(timeoutMs + 10_000), params: { path: { vmId: id } }, body: { command, linuxUser: "root", timeoutMs, ...(stdin ? { stdinBase64: btoa(encoded) } : {}) } })))
    return { exitCode: r.exitCode ?? 124, stdout: r.stdout, stderr: r.stderr }
  }
}
