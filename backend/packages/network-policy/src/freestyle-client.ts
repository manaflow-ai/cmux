import type { FsEndpoint, FsRule, FsRuleSpec, FsTunnel, FsVpc } from "./freestyle-plan.ts"

/**
 * The Freestyle calls the reconciler needs, over plain `fetch` (the
 * `freestyle` SDK assumes Node; the API Worker runs in workerd). Paths and
 * shapes follow freestyle@0.2.10 `dist/*.d.ts`, API version v5.
 */

/** A tunnel as returned to the device: everything to bring it up except the private key. */
export interface FsTunnelDetail extends FsTunnel {
  readonly clientConfig: string
  readonly endpointHost: string | null
  readonly endpointPort: number
  readonly serverPublicKey: string
  readonly routes: ReadonlyArray<string>
}

export interface FreestyleNetworkApi {
  getVpc(slug: string): Promise<FsVpc | null>
  createVpc(input: { slug: string; displayName: string }): Promise<FsVpc>
  deleteVpc(id: string): Promise<void>
  /** Tunnels whose slug starts with `prefix`. */
  listTunnels(prefix: string): Promise<ReadonlyArray<FsTunnelDetail>>
  getTunnel(idOrSlug: string): Promise<FsTunnelDetail | null>
  createTunnel(input: { slug: string; displayName: string; clientPublicKey: string; routes: ReadonlyArray<string>; vpcId: string }): Promise<FsTunnelDetail>
  rotateTunnelKey(id: string, clientPublicKey: string): Promise<FsTunnelDetail>
  attachVpc(tunnelId: string, vpcId: string): Promise<FsTunnelDetail>
  deleteTunnel(id: string): Promise<void>
  /** The private networks a VM is on, or null when the VM does not exist. */
  getVmVpcs(vmId: string): Promise<ReadonlyArray<string> | null>
  /** Every firewall rule in the account (managed or not); the reconciler filters. */
  listAllRules(): Promise<ReadonlyArray<FsRule>>
  createRule(spec: FsRuleSpec, idempotencyKey: string): Promise<FsRule>
  deleteRule(id: string): Promise<void>
}

export class FreestyleError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly method: string,
    readonly path: string
  ) {
    super(`${method} ${path}: ${status} ${code}: ${message}`)
  }
  /** The call may have taken effect even though it failed (timeouts, 5xx): settle by reading back. */
  get indeterminate() {
    return this.status === 0 || this.status >= 500
  }
}

export interface FreestyleClientOptions {
  readonly apiKey: string
  readonly baseUrl?: string
  readonly fetch?: typeof fetch
  /** Per-call deadline. */
  readonly timeoutMs?: number
  /** Observes every call (method, path, status, ms) for latency reports. */
  readonly onCall?: (c: { method: string; path: string; status: number; ms: number }) => void
}

interface RawTunnel {
  tunnelId?: string
  id: string
  slug?: string | null
  clientPublicKey: string
  clientConfig: string
  endpointHost?: string | null
  endpointPort: number
  serverPublicKey: string
  routes: Array<string>
  attachments: Array<{ vpcId: string; ipv4?: string | null; ipv6?: string | null }>
}

interface RawRule {
  id: string
  source: FsEndpoint
  destination: FsEndpoint
  description?: string | null
}

interface RawVpc {
  id: string
  slug?: string | null
  cidr?: string | null
  cidrV6: string
}

const tunnel = (t: RawTunnel): FsTunnelDetail => ({
  tunnelId: t.tunnelId ?? t.id,
  slug: t.slug ?? null,
  clientPublicKey: t.clientPublicKey,
  attachments: t.attachments.map((a) => ({ vpcId: a.vpcId, ipv4: a.ipv4 ?? null, ipv6: a.ipv6 ?? null })),
  clientConfig: t.clientConfig,
  endpointHost: t.endpointHost ?? null,
  endpointPort: t.endpointPort,
  serverPublicKey: t.serverPublicKey,
  routes: t.routes
})

const vpc = (v: RawVpc): FsVpc => ({ id: v.id, slug: v.slug ?? null, cidr: v.cidr ?? null, cidrV6: v.cidrV6 })

/** Drops undefined fields so request bodies and rule identities match Freestyle's echo. */
const clean = (e: FsEndpoint): FsEndpoint => Object.fromEntries(Object.entries(e).filter(([, v]) => v !== undefined && v !== null)) as FsEndpoint

export const createFreestyleClient = (opts: FreestyleClientOptions): FreestyleNetworkApi => {
  const base = (opts.baseUrl ?? "https://api.freestyle.sh").replace(/\/+$/, "")
  const doFetch = opts.fetch ?? fetch
  const timeoutMs = opts.timeoutMs ?? 15_000

  const call = async <T>(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<{ status: number; data: T | null }> => {
    const started = Date.now()
    let status = 0
    try {
      const res = await doFetch(`${base}${path}`, {
        method,
        headers: { Authorization: `Bearer ${opts.apiKey}`, ...(body === undefined ? {} : { "Content-Type": "application/json" }), ...headers },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
        signal: AbortSignal.timeout(timeoutMs)
      })
      status = res.status
      const text = await res.text()
      const data = text ? (JSON.parse(text) as unknown) : null
      if (res.status === 404 && method === "GET") return { status, data: null }
      if (!res.ok) {
        const err = (data ?? {}) as { code?: string; message?: string }
        throw new FreestyleError(res.status, err.code ?? "error", err.message ?? text.slice(0, 200), method, path)
      }
      if (res.status === 202) throw new FreestyleError(202, "backgrounded", "request backgrounded; read back to settle", method, path)
      return { status, data: data as T }
    } catch (e) {
      if (e instanceof FreestyleError) throw e
      throw new FreestyleError(0, "transport", e instanceof Error ? e.message : String(e), method, path)
    } finally {
      opts.onCall?.({ method, path: path.replace(/\/(vpc|tun|fw|vm)-[0-9a-f]+/g, "/$1-…"), status, ms: Date.now() - started })
    }
  }
  const seg = encodeURIComponent

  return {
    async getVpc(slug) {
      const r = await call<RawVpc>("GET", `/v5/vpcs/${seg(slug)}`)
      return r.data ? vpc(r.data) : null
    },
    async createVpc({ slug, displayName }) {
      try {
        // No rules: the VPC is default deny; members do not reach each other until the policy says so.
        const r = await call<{ data?: RawVpc; vpcId?: string } & RawVpc>("POST", "/v5/vpcs", { slug, displayName, firewall: { rules: [] } })
        const d = r.data!
        return vpc(d.data ?? d)
      } catch (e) {
        if (e instanceof FreestyleError && (e.status === 409 || e.indeterminate)) {
          const existing = await this.getVpc(slug)
          if (existing) return existing
        }
        throw e
      }
    },
    async deleteVpc(id) {
      await call("DELETE", `/v5/vpcs/${seg(id)}`).catch((e) => {
        if (!(e instanceof FreestyleError && e.status === 404)) throw e
      })
    },
    async listTunnels(prefix) {
      const r = await call<{ tunnels: Array<RawTunnel>; totalCount?: number }>("GET", "/v5/tunnels")
      const all = r.data?.tunnels ?? []
      // The endpoint is not paginated today; a partial page would hide a revoked device's tunnel, so fail closed.
      if (r.data?.totalCount !== undefined && r.data.totalCount > all.length) throw new FreestyleError(0, "partial_list", `tunnel list returned ${all.length} of ${r.data.totalCount}`, "GET", "/v5/tunnels")
      return all.filter((t) => t.slug?.startsWith(prefix)).map(tunnel)
    },
    async getTunnel(idOrSlug) {
      const r = await call<RawTunnel>("GET", `/v5/tunnels/${seg(idOrSlug)}`)
      return r.data ? tunnel(r.data) : null
    },
    async createTunnel({ slug, displayName, clientPublicKey, routes, vpcId }) {
      try {
        const r = await call<RawTunnel>("POST", "/v5/tunnels", { slug, displayName, clientPublicKey, routes, vpcs: [{ vpcId }] })
        return tunnel(r.data!)
      } catch (e) {
        if (e instanceof FreestyleError && (e.status === 409 || e.indeterminate)) {
          const existing = await this.getTunnel(slug)
          if (existing) return existing
        }
        throw e
      }
    },
    async rotateTunnelKey(id, clientPublicKey) {
      const r = await call<RawTunnel>("POST", `/v5/tunnels/${seg(id)}/rotate-key`, { clientPublicKey })
      return tunnel(r.data!)
    },
    async attachVpc(tunnelId, vpcId) {
      try {
        const r = await call<RawTunnel>("POST", `/v5/tunnels/${seg(tunnelId)}/vpcs/${seg(vpcId)}`, {})
        return tunnel(r.data!)
      } catch (e) {
        if (e instanceof FreestyleError && (e.status === 409 || e.indeterminate)) {
          const t = await this.getTunnel(tunnelId)
          if (t?.attachments.some((a) => a.vpcId === vpcId)) return t
        }
        throw e
      }
    },
    async deleteTunnel(id) {
      await call("DELETE", `/v5/tunnels/${seg(id)}`).catch((e) => {
        if (!(e instanceof FreestyleError && e.status === 404)) throw e
      })
    },
    async getVmVpcs(vmId) {
      const r = await call<{ vpcs?: Array<{ vpcId?: string; vpc?: string }> }>("GET", `/v5/vms/${seg(vmId)}`)
      return r.data ? (r.data.vpcs ?? []).map((v) => v.vpcId ?? v.vpc ?? "").filter(Boolean) : null
    },
    async listAllRules() {
      const out: Array<FsRule> = []
      for (let offset = 0; ; offset += 2000) {
        const r = await call<{ rules: Array<RawRule>; totalCount: number }>("GET", `/v5/firewall/rules?limit=2000&offset=${offset}`)
        const page = r.data?.rules ?? []
        for (const x of page) out.push({ id: x.id, source: clean(x.source), destination: clean(x.destination), description: x.description ?? "" })
        if (page.length < 2000) break
      }
      return out
    },
    async createRule(spec, idempotencyKey) {
      const r = await call<RawRule>(
        "POST",
        "/v5/firewall/rules",
        { action: "allow", source: clean(spec.source), destination: clean(spec.destination), description: spec.description },
        { "Idempotency-Key": idempotencyKey }
      )
      const d = r.data!
      return { id: d.id, source: clean(d.source), destination: clean(d.destination), description: d.description ?? spec.description }
    },
    async deleteRule(id) {
      await call("DELETE", `/v5/firewall/rules/${seg(id)}`).catch((e) => {
        if (!(e instanceof FreestyleError && e.status === 404)) throw e
      })
    }
  }
}
