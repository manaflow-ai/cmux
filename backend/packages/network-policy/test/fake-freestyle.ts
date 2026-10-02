import { FreestyleError, type FreestyleNetworkApi, type FsTunnelDetail } from "../src/freestyle-client.ts"
import type { FsRule, FsRuleSpec, FsVpc } from "../src/freestyle-plan.ts"

/**
 * In-memory Freestyle with the semantics the reconciler relies on: slugs are
 * unique, rules die with the tunnel/VM/VPC they name, deletes of missing
 * things are 404. `failNext` injects failures (including "applied but the
 * response was lost").
 */
export class FakeFreestyle implements FreestyleNetworkApi {
  vpcs = new Map<string, FsVpc>()
  tunnels = new Map<string, FsTunnelDetail>()
  rules = new Map<string, FsRule>()
  /** Rules owned by someone else in the shared account. */
  foreignRuleIds = new Set<string>()
  calls: Array<string> = []
  private n = 0
  private failures: Array<{ op: string; mode: "before" | "after"; status: number }> = []

  failNext(op: string, mode: "before" | "after", status = 503) {
    this.failures.push({ op, mode, status })
  }

  private id(prefix: string) {
    return `${prefix}-${(++this.n).toString(16).padStart(8, "0")}`
  }

  private async step<T>(op: string, fn: () => T): Promise<T> {
    this.calls.push(op)
    const i = this.failures.findIndex((f) => f.op === op)
    const f = i >= 0 ? this.failures.splice(i, 1)[0] : undefined
    if (f?.mode === "before") throw new FreestyleError(f.status, "injected", "injected failure", "X", op)
    const r = fn()
    if (f?.mode === "after") throw new FreestyleError(f.status, "injected", "injected failure after apply", "X", op)
    return r
  }

  async getVpc(slug: string) {
    return this.step("getVpc", () => [...this.vpcs.values()].find((v) => v.slug === slug || v.id === slug) ?? null)
  }
  async createVpc({ slug }: { slug: string }) {
    return this.step("createVpc", () => {
      if ([...this.vpcs.values()].some((v) => v.slug === slug)) throw new FreestyleError(409, "conflict", "slug taken", "POST", "/v5/vpcs")
      const v: FsVpc = { id: this.id("vpc"), slug, cidr: `10.${this.vpcs.size + 20}.0.0/24`, cidrV6: `fd0${this.vpcs.size}::/64` }
      this.vpcs.set(v.id, v)
      return v
    }).catch(async (e) => {
      if (e instanceof FreestyleError && (e.status === 409 || e.indeterminate)) {
        const v = await this.getVpc(slug)
        if (v) return v
      }
      throw e
    })
  }
  async deleteVpc(id: string) {
    return this.step("deleteVpc", () => {
      this.vpcs.delete(id)
      for (const [rid, r] of this.rules) if (r.source.vpcId === id || r.destination.vpcId === id) this.rules.delete(rid)
    })
  }
  async listTunnels(prefix: string) {
    return this.step("listTunnels", () => [...this.tunnels.values()].filter((t) => t.slug?.startsWith(prefix)))
  }
  async getTunnel(idOrSlug: string) {
    return this.step("getTunnel", () => [...this.tunnels.values()].find((t) => t.tunnelId === idOrSlug || t.slug === idOrSlug) ?? null)
  }
  async createTunnel(input: { slug: string; clientPublicKey: string; routes: ReadonlyArray<string>; vpcId: string }) {
    return this.step("createTunnel", () => {
      if ([...this.tunnels.values()].some((t) => t.slug === input.slug)) throw new FreestyleError(409, "conflict", "slug taken", "POST", "/v5/tunnels")
      const id = this.id("tun")
      const t: FsTunnelDetail = {
        tunnelId: id,
        slug: input.slug,
        clientPublicKey: input.clientPublicKey,
        attachments: [{ vpcId: input.vpcId, ipv4: `10.20.0.${this.tunnels.size + 2}`, ipv6: null }],
        clientConfig: `[Interface]\nPrivateKey = \nAddress = 100.64.0.1/32\n\n[Peer]\nPublicKey = SERVER\nAllowedIPs = ${input.routes.join(", ")}\nEndpoint = ${id}.vpn:51820\n`,
        endpointHost: `${id}.vpn`,
        endpointPort: 51820,
        serverPublicKey: "SERVER",
        routes: input.routes
      }
      this.tunnels.set(id, t)
      return t
    }).catch(async (e) => {
      if (e instanceof FreestyleError && (e.status === 409 || e.indeterminate)) {
        const t = await this.getTunnel(input.slug)
        if (t) return t
      }
      throw e
    })
  }
  async rotateTunnelKey(id: string, clientPublicKey: string) {
    return this.step("rotateTunnelKey", () => {
      const t = { ...this.tunnels.get(id)!, clientPublicKey }
      this.tunnels.set(id, t)
      return t
    })
  }
  async attachVpc(tunnelId: string, vpcId: string) {
    return this.step("attachVpc", () => {
      const t = this.tunnels.get(tunnelId)!
      const next = { ...t, attachments: [...t.attachments, { vpcId, ipv4: "10.20.0.99", ipv6: null }] }
      this.tunnels.set(tunnelId, next)
      return next
    })
  }
  async deleteTunnel(id: string) {
    return this.step("deleteTunnel", () => {
      this.tunnels.delete(id)
      for (const [rid, r] of this.rules) if (r.source.tunnelId === id || r.destination.tunnelId === id) this.rules.delete(rid)
    })
  }
  /** vmId -> VPC ids; a VM missing here is reported as on no network. */
  vmVpcs = new Map<string, Array<string>>()
  /** When true, a VM without an entry is on every VPC (the usual test setup). */
  autoMember = true
  async getVmVpcs(vmId: string) {
    return this.step("getVmVpcs", () => this.vmVpcs.get(vmId) ?? (this.autoMember ? [...this.vpcs.keys()] : []))
  }
  async listAllRules() {
    return this.step("listRules", () => [...this.rules.values()])
  }
  async createRule(spec: FsRuleSpec) {
    return this.step("createRule", () => {
      const r: FsRule = { ...spec, id: this.id("fw") }
      this.rules.set(r.id, r)
      return r
    })
  }
  async deleteRule(id: string) {
    return this.step("deleteRule", () => {
      if (this.foreignRuleIds.has(id)) throw new Error("test bug: reconciler deleted a foreign rule")
      this.rules.delete(id)
    })
  }

  /** Whether some rule admits traffic from a tunnel to a VM on a TCP port (stateful return assumed). */
  allows(tunnelId: string, vmId: string, port: number, vpcId: string): boolean {
    return [...this.rules.values()].some((r) => {
      const srcOk = r.source.tunnelId === tunnelId || r.source.vpcId === vpcId
      const dstOk = r.destination.vmId === vmId || r.destination.vpcId === vpcId
      const portOk = r.destination.port === undefined || (r.destination.port === port && r.destination.protocol === "tcp")
      return srcOk && dstOk && portOk && (r.destination.protocol === undefined || r.destination.protocol === "tcp")
    })
  }
}
