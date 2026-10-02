import type { CompiledNetwork } from "./compile.ts"
import { FreestyleError, type FreestyleNetworkApi, type FsTunnelDetail } from "./freestyle-client.ts"
import { MANAGED_MARKER, fnv64, planFreestyle, teamTag, tunnelSlug, vpcSlug, type FsAction, type FsActual, type FsPlan, type FsRule, type FsVpc } from "./freestyle-plan.ts"
import type { Directory } from "./types.ts"

/**
 * Converges Freestyle to the compiled policy: read the managed resources,
 * plan, execute, and plan again until nothing is left (or a pass limit).
 * Every create is idempotent by construction: VPCs and tunnels by slug (a
 * conflict or an indeterminate failure reads the slug back), rules by
 * re-reading before each pass. Runs outside the TeamDO reducer; its report
 * returns to TeamDO as a system op (spec sync-and-transport section 7).
 */

export interface ActionOutcome {
  readonly action: FsAction
  readonly ok: boolean
  readonly ms: number
  readonly error?: { readonly status: number; readonly code: string; readonly message: string; readonly indeterminate: boolean }
}

export interface DeviceTunnel {
  readonly install: string
  readonly tunnelId: string
  /** WireGuard config with a blank PrivateKey and `PersistentKeepalive = 25` added; contains no secret. */
  readonly clientConfig: string
  readonly endpoint: string | null
  readonly address_v4: string | null
  readonly address_v6: string | null
  readonly serverPublicKey: string
}

export interface ReconcileReport {
  readonly team: string
  readonly passes: number
  readonly converged: boolean
  readonly outcomes: ReadonlyArray<ActionOutcome>
  readonly deferred: FsPlan["deferred"]
  /** Actions the FIRST pass needed although the previous run converged: drift. */
  readonly drift: ReadonlyArray<FsAction>
  readonly vpc: { readonly id: string; readonly cidr: string | null; readonly cidrV6: string } | null
  readonly tunnels: ReadonlyArray<DeviceTunnel>
  readonly startedAt: number
  readonly ms: number
}

export interface ReconcileOptions {
  readonly maxPasses?: number
  /** Parallel rule creates/deletes per batch. */
  readonly concurrency?: number
  /** True when the last recorded run converged; non-empty first-pass actions are then reported as drift. */
  readonly expectConverged?: boolean
  readonly now?: () => number
}

/** Freestyle omits `PersistentKeepalive`; NAT'd devices need it (spec "How a Mac joins" step 3). */
export const withKeepalive = (config: string): string => {
  const lines = config.split("\n")
  if (lines.some((l) => /^\s*PersistentKeepalive\s*=/.test(l))) return config
  const peer = lines.findIndex((l) => l.trim() === "[Peer]")
  if (peer < 0) return config
  let end = lines.findIndex((l, i) => i > peer && l.trim().startsWith("["))
  if (end < 0) end = lines.length
  // Insert after the section's last non-empty line.
  let at = end
  while (at > peer + 1 && lines[at - 1]!.trim() === "") at--
  lines.splice(at, 0, "PersistentKeepalive = 25")
  return lines.join("\n")
}

export const readActual = async (api: FreestyleNetworkApi, team: string): Promise<FsActual & { tunnelDetails: ReadonlyArray<FsTunnelDetail> }> => {
  const [vpc, tunnels, rules] = await Promise.all([api.getVpc(vpcSlug(team)), api.listTunnels(`${vpcSlug(team)}-`), api.listRules(`${MANAGED_MARKER} team=${teamTag(team)} `)])
  return { vpc, tunnels, rules, tunnelDetails: tunnels }
}

const errorOf = (e: unknown) =>
  e instanceof FreestyleError
    ? { status: e.status, code: e.code, message: e.message, indeterminate: e.indeterminate }
    : { status: 0, code: "exception", message: e instanceof Error ? e.message : String(e), indeterminate: true }

type Effect =
  | { readonly kind: "none" }
  | { readonly kind: "vpc"; readonly vpc: FsVpc }
  | { readonly kind: "tunnel"; readonly tunnel: FsTunnelDetail }
  | { readonly kind: "rule"; readonly rule: FsRule }

const execute = async (api: FreestyleNetworkApi, team: string, a: FsAction): Promise<Effect> => {
  switch (a.op) {
    case "rule.delete":
      await api.deleteRule(a.ruleId)
      return { kind: "none" }
    case "tunnel.delete":
      await api.deleteTunnel(a.tunnelId)
      return { kind: "none" }
    case "vpc.delete":
      await api.deleteVpc(a.vpcId)
      return { kind: "none" }
    case "vpc.create":
      return { kind: "vpc", vpc: await api.createVpc({ slug: a.slug, displayName: `cmux team network ${teamTag(team)}` }) }
    case "tunnel.create":
      return { kind: "tunnel", tunnel: await api.createTunnel({ slug: a.slug, displayName: `cmux device ${a.install.slice(0, 12)}`, clientPublicKey: a.publicKey, routes: a.routes, vpcId: a.vpcId }) }
    case "tunnel.rotate":
      return { kind: "tunnel", tunnel: await api.rotateTunnelKey(a.tunnelId, a.publicKey) }
    case "tunnel.attach":
      return { kind: "tunnel", tunnel: await api.attachVpc(a.tunnelId, a.vpcId) }
    case "rule.create":
      // The key is stable for the same rule in the same team, so a retried create can be deduplicated server-side if Freestyle honors it.
      return { kind: "rule", rule: await api.createRule(a.spec, `cmux-np-${fnv64(`${team}:${a.key}`)}`) }
  }
}

type Working = { vpc: FsVpc | null; tunnelDetails: Array<FsTunnelDetail>; rules: Array<FsRule> }

/** Applies a successful action to the working copy, so the next phase plans without a re-read. */
const merge = (w: Working, a: FsAction, e: Effect) => {
  if (a.op === "tunnel.delete") {
    w.tunnelDetails = w.tunnelDetails.filter((t) => t.tunnelId !== a.tunnelId)
    w.rules = w.rules.filter((r) => r.source.tunnelId !== a.tunnelId && r.destination.tunnelId !== a.tunnelId)
  } else if (a.op === "rule.delete") w.rules = w.rules.filter((r) => r.id !== a.ruleId)
  else if (e.kind === "vpc") w.vpc = e.vpc
  else if (e.kind === "tunnel") w.tunnelDetails = [...w.tunnelDetails.filter((t) => t.tunnelId !== e.tunnel.tunnelId), e.tunnel]
  else if (e.kind === "rule") w.rules = [...w.rules, e.rule]
}

const asActual = (w: Working): FsActual => ({ vpc: w.vpc, tunnels: w.tunnelDetails, rules: w.rules })

const PHASES: ReadonlyArray<ReadonlyArray<FsAction["op"]>> = [["tunnel.delete"], ["rule.delete"], ["vpc.create"], ["tunnel.create", "tunnel.rotate", "tunnel.attach"], ["rule.create"]]

const parallel = async <T, R>(items: ReadonlyArray<T>, n: number, fn: (t: T) => Promise<R>): Promise<Array<R>> => {
  const out: Array<R> = new Array(items.length)
  let next = 0
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (next < items.length) {
        const i = next++
        out[i] = await fn(items[i]!)
      }
    })
  )
  return out
}

export const reconcile = async (api: FreestyleNetworkApi, team: string, compiled: CompiledNetwork, dir: Directory, opts: ReconcileOptions = {}): Promise<ReconcileReport> => {
  const now = opts.now ?? Date.now
  const startedAt = now()
  const maxPasses = opts.maxPasses ?? 4
  const concurrency = opts.concurrency ?? 8
  const outcomes: Array<ActionOutcome> = []
  let drift: ReadonlyArray<FsAction> = []
  let deferred: FsPlan["deferred"] = []
  let actual = await readActual(api, team)
  let passes = 0
  let converged = false

  const run = async (a: FsAction): Promise<ActionOutcome & { effect?: Effect }> => {
    const t = now()
    try {
      const effect = await execute(api, team, a)
      return { action: a, ok: true, ms: now() - t, effect }
    } catch (e) {
      return { action: a, ok: false, ms: now() - t, error: errorOf(e) }
    }
  }

  // A pass drives a working copy to an empty plan one phase at a time (revocations first; each
  // phase plans from the previous phase's results, so a new tunnel's rules follow in the same
  // pass), then re-reads Freestyle to verify. A failure ends the pass early; the re-read settles it.
  while (passes < maxPasses) {
    const w: Working = { vpc: actual.vpc, tunnelDetails: [...actual.tunnelDetails], rules: [...actual.rules] }
    let worked = false
    for (let step = 0; step < PHASES.length * 2; step++) {
      const plan = planFreestyle(team, compiled, dir, asActual(w))
      deferred = plan.deferred
      if (passes === 0 && step === 0 && opts.expectConverged) drift = plan.actions
      const group = PHASES.map((ops) => plan.actions.filter((x) => ops.includes(x.op))).find((g) => g.length > 0)
      if (!group) break
      worked = true
      const results = await parallel(group, concurrency, run)
      for (const { effect, ...o } of results) {
        outcomes.push(o)
        if (o.ok && effect) merge(w, o.action, effect)
      }
      if (results.some((r) => !r.ok)) break
    }
    if (!worked) {
      converged = deferred.every((d) => d.reason.includes("no provider id"))
      break
    }
    passes++
    actual = await readActual(api, team)
  }

  const vpc = actual.vpc
  const devices = new Map(dir.devices.map((d) => [tunnelSlug(team, d.install), d.install]))
  const tunnels: Array<DeviceTunnel> = []
  for (const t of actual.tunnelDetails) {
    const install = t.slug ? devices.get(t.slug) : undefined
    if (!install) continue
    const att = vpc ? t.attachments.find((a) => a.vpcId === vpc.id) : undefined
    tunnels.push({
      install,
      tunnelId: t.tunnelId,
      clientConfig: withKeepalive(t.clientConfig),
      endpoint: t.endpointHost ? `${t.endpointHost}:${t.endpointPort}` : null,
      address_v4: att?.ipv4 ?? null,
      address_v6: att?.ipv6 ?? null,
      serverPublicKey: t.serverPublicKey
    })
  }
  return {
    team,
    passes,
    converged,
    outcomes,
    deferred,
    drift,
    vpc: vpc ? { id: vpc.id, cidr: vpc.cidr, cidrV6: vpc.cidrV6 } : null,
    tunnels: tunnels.sort((a, b) => (a.install < b.install ? -1 : 1)),
    startedAt,
    ms: now() - startedAt
  }
}

/**
 * Tears down everything this reconciler made for a team (team deletion, test
 * cleanup). Touches only marker-tagged rules and team-slug tunnels and VPC.
 */
export const teardown = async (api: FreestyleNetworkApi, team: string): Promise<ReadonlyArray<ActionOutcome>> => {
  const actual = await readActual(api, team)
  const outcomes: Array<ActionOutcome> = []
  const timed = async (action: FsAction, fn: () => Promise<void>) => {
    const t = Date.now()
    try {
      await fn()
      outcomes.push({ action, ok: true, ms: Date.now() - t })
    } catch (e) {
      outcomes.push({ action, ok: false, ms: Date.now() - t, error: errorOf(e) })
    }
  }
  for (const t of actual.tunnels) await timed({ op: "tunnel.delete", tunnelId: t.tunnelId, slug: t.slug ?? "", why: "teardown" }, () => api.deleteTunnel(t.tunnelId))
  for (const r of actual.rules) await timed({ op: "rule.delete", ruleId: r.id, why: "teardown" }, () => api.deleteRule(r.id))
  if (actual.vpc) {
    const id = actual.vpc.id
    await timed({ op: "vpc.delete", vpcId: id }, () => api.deleteVpc(id))
  }
  return outcomes
}
