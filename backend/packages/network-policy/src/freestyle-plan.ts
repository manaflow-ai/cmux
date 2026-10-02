import { ruleKey, type CompiledNetwork, type CompiledRule, type Endpoint } from "./compile.ts"
import type { Directory, Proto } from "./types.ts"

/**
 * Phase 1 enforcement (spec "Reconciler" (a)): bind the compiled rules to
 * Freestyle ids and diff them against what Freestyle holds. One VPC per team
 * (D37) created with NO members-reach-each-other rule, so the VPC is default
 * deny; one tunnel per (device, team); one firewall rule per compiled rule.
 */

/** Marks every Freestyle resource this reconciler owns. Nothing without it is ever changed or deleted. */
export const MANAGED_MARKER = "cmux-np/v1"

export interface FsEndpoint {
  readonly vmId?: string
  readonly vpcId?: string
  readonly tunnelId?: string
  readonly cidr?: string
  readonly public?: true
  readonly port?: number
  readonly protocol?: Proto
}

export interface FsRuleSpec {
  readonly source: FsEndpoint
  readonly destination: FsEndpoint
  readonly description: string
}

export interface FsRule extends FsRuleSpec {
  readonly id: string
}

export interface FsTunnel {
  readonly tunnelId: string
  readonly slug: string | null
  readonly displayName?: string | null
  readonly clientPublicKey: string
  readonly attachments: ReadonlyArray<{ readonly vpcId: string; readonly ipv4?: string | null; readonly ipv6?: string | null }>
}

export interface FsVpc {
  readonly id: string
  readonly slug: string | null
  readonly displayName?: string | null
  readonly cidr: string | null
  readonly cidrV6: string
}

/** What Freestyle holds for one team, already filtered to managed resources. */
export interface FsActual {
  readonly vpc: FsVpc | null
  readonly tunnels: ReadonlyArray<FsTunnel>
  readonly rules: ReadonlyArray<FsRule>
  /** Provider VM ids confirmed on the team VPC; others are never named in a rule (an admin-supplied id could name anyone's VM). */
  readonly memberVms?: ReadonlySet<string>
}

export type FsAction =
  | { readonly op: "rule.delete"; readonly ruleId: string; readonly why: string }
  | { readonly op: "tunnel.delete"; readonly tunnelId: string; readonly slug: string; readonly why: string }
  | { readonly op: "vpc.create"; readonly slug: string }
  /** Only teardown and cleanup issue this; the planner never deletes a VPC. */
  | { readonly op: "vpc.delete"; readonly vpcId: string }
  /** Dev/staging expiry refreshes (display name only). */
  | { readonly op: "vpc.refresh"; readonly vpcId: string }
  | { readonly op: "tunnel.refresh"; readonly tunnelId: string }
  | { readonly op: "tunnel.create"; readonly install: string; readonly slug: string; readonly publicKey: string; readonly vpcId: string; readonly routes: ReadonlyArray<string> }
  | { readonly op: "tunnel.rotate"; readonly install: string; readonly tunnelId: string; readonly publicKey: string }
  | { readonly op: "tunnel.attach"; readonly install: string; readonly tunnelId: string; readonly vpcId: string }
  | { readonly op: "rule.create"; readonly spec: FsRuleSpec; readonly key: string }

export interface FsPlan {
  /** Revocations first (rule and tunnel deletes), then creates. */
  readonly actions: ReadonlyArray<FsAction>
  /** Compiled rules that cannot be bound yet (a tunnel or VPC still to create, a machine without a provider id). */
  readonly deferred: ReadonlyArray<{ readonly key: string; readonly reason: string }>
  readonly desiredRules: number
}

/** FNV-1a 64-bit, hex. Deterministic and synchronous (used for slugs, not security). */
export const fnv64 = (s: string): string => {
  let h = 0xcbf29ce484222325n
  for (const b of new TextEncoder().encode(s)) {
    h ^= BigInt(b)
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn
  }
  return h.toString(16).padStart(16, "0")
}

/**
 * Where a team's resources live in the shared Freestyle account. Production
 * uses `cmuxnp-<tag>`; development and staging use `cmuxnp-dev-<tag>` and
 * `cmuxnp-staging-<tag>`, and every resource there carries an expiry (in its
 * display name or rule description) that reconciles refresh and that the
 * cleanup job (cleanup.ts) honors. A bare team id string means production.
 */
export interface NetworkScope {
  readonly team: string
  readonly env?: "dev" | "staging" | null
  /** Expiry window for dev/staging resources (default 7 days). */
  readonly ttlMs?: number
  /** Clock for expiry stamps (default Date.now). */
  readonly now?: () => number
}
export type Scope = string | NetworkScope
export const DEFAULT_TTL_MS = 7 * 24 * 3600_000
export const scopeOf = (s: Scope): NetworkScope => (typeof s === "string" ? { team: s, env: null } : s)
const envPart = (s: Scope) => {
  const env = scopeOf(s).env
  return env ? `${env}-` : ""
}
/** Seconds since epoch when a resource created or refreshed now expires; null for production (no expiry). */
export const expiryFor = (s: Scope): number | null => {
  const sc = scopeOf(s)
  if (!sc.env) return null
  return Math.floor(((sc.now ?? Date.now)() + (sc.ttlMs ?? DEFAULT_TTL_MS)) / 1000)
}
/** The `exp=<seconds>` stamp in a display name or description, if any. */
export const parseExpiry = (text: string | null | undefined): number | null => {
  const m = /(?:^| )exp=(\d{9,12})(?: |$)/.exec(text ?? "")
  return m ? Number(m[1]) : null
}

/** Short opaque team tag: the account is shared, so raw team ids never appear in provider slugs. */
export const teamTag = (team: Scope) => fnv64(`cmux-np:team:${scopeOf(team).team}`).slice(0, 12)
export const vpcSlug = (s: Scope) => `cmuxnp-${envPart(s)}${teamTag(s)}`
export const tunnelSlug = (s: Scope, install: string) => `${vpcSlug(s)}-${fnv64(`cmux-np:tunnel:${scopeOf(s).team}:${install}`).slice(0, 16)}`
/** Prefix every managed rule of this scope's team starts with. */
export const rulePrefix = (s: Scope) => {
  const env = scopeOf(s).env
  return `${MANAGED_MARKER} ${env ? `env=${env} ` : ""}team=${teamTag(s)} `
}
export const ruleDescription = (s: Scope, key: string) => {
  const exp = expiryFor(s)
  return `${rulePrefix(s)}${exp ? `exp=${exp} ` : ""}rule=${key}`
}
/** Display name for a managed VPC or tunnel; dev/staging names carry the expiry. */
export const resourceName = (s: Scope, what: string) => {
  const env = scopeOf(s).env
  const exp = expiryFor(s)
  return `cmux-np ${env ? `env=${env} ` : ""}team=${teamTag(s)} ${what}${exp ? ` exp=${exp}` : ""}`
}
export const isManagedRule = (s: Scope, r: Pick<FsRuleSpec, "description">) => r.description.startsWith(rulePrefix(s))

/** Canonical identity of a Freestyle rule: its two endpoints (descriptions never affect equality). */
export const fsRuleIdentity = (r: Pick<FsRuleSpec, "source" | "destination">): string => {
  const ep = (e: FsEndpoint) => [e.vmId ?? "", e.vpcId ?? "", e.tunnelId ?? "", e.cidr ?? "", e.port ?? "", e.protocol ?? ""].join(",")
  return `${ep(r.source)}>${ep(r.destination)}`
}

export interface Bindings {
  readonly vpcId: string | null
  readonly tunnels: ReadonlyMap<string, string>
  readonly machines: ReadonlyMap<string, string>
}

export const bindingsFrom = (team: Scope, dir: Directory, actual: FsActual): Bindings => {
  const bySlug = new Map(actual.tunnels.filter((t) => t.slug).map((t) => [t.slug!, t]))
  const tunnels = new Map<string, string>()
  for (const d of dir.devices) {
    const t = bySlug.get(tunnelSlug(team, d.install))
    // A tunnel binds only once it is attached to the team VPC, so a rule never names an unattached tunnel.
    if (t && actual.vpc && t.attachments.some((a) => a.vpcId === actual.vpc!.id)) tunnels.set(d.install, t.tunnelId)
  }
  const machines = new Map<string, string>()
  for (const m of dir.machines) if (m.provider_id && actual.memberVms?.has(m.provider_id)) machines.set(m.id, m.provider_id)
  return { vpcId: actual.vpc?.id ?? null, tunnels, machines }
}

const bindEndpoint = (e: Endpoint, b: Bindings): FsEndpoint | string => {
  switch (e.kind) {
    case "network":
      return b.vpcId ? { vpcId: b.vpcId } : "team VPC not created yet"
    case "device": {
      const t = b.tunnels.get(e.install)
      return t ? { tunnelId: t } : `device ${e.install} has no attached tunnel yet`
    }
    case "machine": {
      const v = b.machines.get(e.id)
      return v ? { vmId: v } : `machine ${e.id} has no provider id on the team VPC`
    }
    case "cidr":
      return { cidr: e.cidr }
  }
}

export const bindRule = (team: Scope, r: CompiledRule, b: Bindings): FsRuleSpec | string => {
  const source = bindEndpoint(r.src, b)
  if (typeof source === "string") return source
  const dst = bindEndpoint(r.dst, b)
  if (typeof dst === "string") return dst
  const destination: FsEndpoint = { ...dst, ...(r.port !== undefined ? { port: r.port } : {}), ...(r.proto ? { protocol: r.proto } : {}) }
  return { source, destination, description: ruleDescription(team, ruleKey(r)) }
}

/**
 * The actions that move Freestyle from `actual` to the compiled policy.
 * Pure; the reconciler executes the actions and plans again until empty.
 */
export const planFreestyle = (team: Scope, compiled: CompiledNetwork, dir: Directory, actual: FsActual): FsPlan => {
  const actions: Array<FsAction> = []
  const deferred: Array<{ key: string; reason: string }> = []
  const slug = vpcSlug(team)
  const bindings = bindingsFrom(team, dir, actual)

  // Desired tunnels: every active member device that sent a WireGuard key.
  const wanted = new Map<string, { install: string; publicKey: string }>()
  const devices = new Map(dir.devices.map((d) => [d.install, d]))
  for (const install of compiled.devices) {
    const d = devices.get(install)
    if (d?.wg_public_key) wanted.set(tunnelSlug(team, install), { install, publicKey: d.wg_public_key })
  }

  // Desired rules, bound where possible.
  const desired = new Map<string, { spec: FsRuleSpec; key: string }>()
  for (const r of compiled.rules) {
    const spec = bindRule(team, r, bindings)
    if (typeof spec === "string") deferred.push({ key: ruleKey(r), reason: spec })
    else desired.set(fsRuleIdentity(spec), { spec, key: ruleKey(r) })
  }

  // 1. Revocations: tunnels of devices no longer wanted, then rules no longer wanted.
  const deletedTunnels = new Set<string>()
  for (const t of actual.tunnels) {
    if (t.slug && !wanted.has(t.slug)) {
      actions.push({ op: "tunnel.delete", tunnelId: t.tunnelId, slug: t.slug, why: "device revoked or left the team" })
      deletedTunnels.add(t.tunnelId)
    }
  }
  const kept = new Set<string>()
  for (const r of actual.rules) {
    const id = fsRuleIdentity(r)
    // Keep one rule per identity; duplicates (a lost create retried) are deleted.
    if (desired.has(id) && !kept.has(id)) {
      kept.add(id)
      continue
    }
    // Rules die with their tunnel (Freestyle dependency), so skip ones a tunnel delete removes.
    if (r.source.tunnelId && deletedTunnels.has(r.source.tunnelId)) continue
    if (r.destination.tunnelId && deletedTunnels.has(r.destination.tunnelId)) continue
    actions.push({ op: "rule.delete", ruleId: r.id, why: "not in the compiled policy" })
  }

  // 2. Creates.
  if (!actual.vpc) actions.push({ op: "vpc.create", slug })
  if (actual.vpc) {
    const routes = [actual.vpc.cidr, actual.vpc.cidrV6].filter((c): c is string => Boolean(c))
    const bySlug = new Map(actual.tunnels.filter((t) => t.slug).map((t) => [t.slug!, t]))
    for (const [tslug, w] of wanted) {
      const t = bySlug.get(tslug)
      if (!t) actions.push({ op: "tunnel.create", install: w.install, slug: tslug, publicKey: w.publicKey, vpcId: actual.vpc.id, routes })
      else {
        if (t.clientPublicKey !== w.publicKey) actions.push({ op: "tunnel.rotate", install: w.install, tunnelId: t.tunnelId, publicKey: w.publicKey })
        if (!t.attachments.some((a) => a.vpcId === actual.vpc!.id)) actions.push({ op: "tunnel.attach", install: w.install, tunnelId: t.tunnelId, vpcId: actual.vpc.id })
      }
    }
  }
  const have = new Set(actual.rules.map(fsRuleIdentity))
  for (const [id, d] of desired) if (!have.has(id)) actions.push({ op: "rule.create", spec: d.spec, key: d.key })

  return { actions, deferred, desiredRules: compiled.rules.length }
}
