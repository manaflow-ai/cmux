import {
  compileNetwork,
  mayAssignTag,
  parsePolicy,
  previewPolicy,
  validatePolicy,
  type Directory,
  type DirectoryDevice,
  type DirectoryMachine,
  type Policy
} from "@cmux/network-policy"
import type { Principal, ReduceContext, ReduceResult } from "@cmux/ownership"
import {
  NetworkDeviceJoin,
  NetworkDeviceRevoke,
  NetworkMachineRegister,
  NetworkMachineRemove,
  NetworkMachineTag,
  NetworkPolicyApply,
  NetworkPolicyRollback,
  ReconcileRecordParams,
  type DeviceTunnel,
  type NetworkDevice,
  type NetworkMachine,
  type PolicyVersion
} from "@cmux/protocol"
import { Schema } from "effect"
import { decodeParams, reject } from "./common.ts"

/**
 * TeamDO's network section (spec network-policy.md): policy versions, the
 * network directory (devices with WireGuard keys, VPC member machines) and the
 * reconciler's last result. Pure: the reconciler runs in TeamDO.onWake after
 * commit and reports back through `network.reconcile.record`.
 *
 * Everything here is visible to every team member (snapshots carry the whole
 * TeamState): it holds public keys and tunnel configs with a blank PrivateKey,
 * never a secret.
 */

type Version = typeof PolicyVersion.Type
type Device = typeof NetworkDevice.Type
type Machine = typeof NetworkMachine.Type
type Tunnel = typeof DeviceTunnel.Type

export interface ReconcileStatus {
  /** Bumped by every change that affects compiled output. */
  readonly desired_seq: number
  /** desired_seq of the last recorded reconcile. */
  readonly applied_seq: number
  readonly last: {
    readonly at: number
    readonly ms: number
    readonly converged: boolean
    readonly configured: boolean
    readonly actions: number
    readonly failures: ReadonlyArray<string>
    readonly drift: ReadonlyArray<string>
    readonly deferred: number
    /** Unmanaged Freestyle rules that grant access to team resources: the policy is not the only gate while any exist. */
    readonly foreign?: ReadonlyArray<string>
    readonly error?: string
  } | null
  readonly vpc_id: string | null
}

export interface NetworkState {
  readonly versions: ReadonlyArray<Version>
  readonly devices: Readonly<Record<string, Device>>
  readonly machines: Readonly<Record<string, Machine>>
  readonly reconcile: ReconcileStatus
}

export const MAX_VERSIONS = 100

export const initialNetwork = (): NetworkState => ({
  versions: [],
  devices: {},
  machines: {},
  reconcile: { desired_seq: 0, applied_seq: 0, last: null, vpc_id: null }
})

/**
 * The policy in force before an admin applies one: admins reach everything,
 * members reach the team VM (SSH, HTTPS) and their own devices and machines.
 */
export const DEFAULT_POLICY = `{
  // Built-in default. Apply your own with network.policy.apply.
  "tagOwners": { "tag:team-vm": ["autogroup:admin"] },
  "acls": [
    { "action": "accept", "src": ["autogroup:admin"], "dst": ["*:*"] },
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm:22,443", "autogroup:self:*"] }
  ],
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:team-vm"], "users": ["autogroup:nonroot"] }
  ]
}`

interface TeamLike {
  readonly team: { readonly id: string } | null
  readonly members: Readonly<Record<string, { readonly user: string; readonly role: "owner" | "admin" | "member" }>>
  readonly network?: NetworkState
}

/** State written before the network section existed wakes without it. */
export const net = (s: TeamLike): NetworkState => s.network ?? initialNetwork()

export const currentVersion = (n: NetworkState): Version | undefined => n.versions[n.versions.length - 1]

export const effectiveSource = (n: NetworkState): string => currentVersion(n)?.source ?? DEFAULT_POLICY

export const effectivePolicy = (n: NetworkState): Policy => {
  const p = parsePolicy(effectiveSource(n))
  if (p.ok) return p.value
  // A stored version always parsed when applied; parser changes must stay compatible. Fail closed.
  return { groups: {}, tagOwners: {}, hosts: {}, acls: [], ssh: [], tests: [] }
}

export const directoryOf = (s: TeamLike): Directory => {
  const n = net(s)
  return {
    members: Object.values(s.members).map((m) => ({ user: m.user, role: m.role })),
    devices: Object.values(n.devices).map(
      (d): DirectoryDevice => ({ install: d.install, user: d.user, wg_public_key: d.wg_public_key, ...(d.revoked_at !== null ? { revoked: true } : {}) })
    ),
    machines: Object.values(n.machines).map(
      (m): DirectoryMachine => ({
        id: m.id,
        tags: m.tags,
        ...(m.provider_id ? { provider_id: m.provider_id } : {}),
        ...(m.owner_user ? { owner_user: m.owner_user } : {}),
        ...(m.classes.length > 0 ? { classes: m.classes } : {}),
        ...(m.address ? { address: m.address } : {})
      })
    )
  }
}

/** Whether the network has anything to enforce (no VPC is created for a team that never used it). */
export const networkInUse = (n: NetworkState) => Object.keys(n.devices).length > 0 || Object.keys(n.machines).length > 0

const isAdmin = (s: TeamLike, p: Principal) => {
  const role = p.user ? s.members[p.user]?.role : undefined
  return role === "owner" || role === "admin"
}

const bump = (n: NetworkState): NetworkState => ({ ...n, reconcile: { ...n.reconcile, desired_seq: n.reconcile.desired_seq + 1 } })

const withNet = <S extends TeamLike>(s: S, n: NetworkState): S => ({ ...s, network: n })

type R<S> = ReduceResult<S>

const commitVersion = <S extends TeamLike>(state: S, source: string, ctx: ReduceContext, rollbackOf: number | null): R<S> => {
  const n = net(state)
  const v = validatePolicy(source, directoryOf(state))
  if (!v.ok) return reject("policy.invalid", `policy rejected: ${v.issues.length} issue(s)`, { issues: v.issues })
  const cur = currentVersion(n)
  if (cur && cur.canonical === v.value.canonical && cur.source === source && rollbackOf === null) return { ok: true, state, value: cur, changed: false }
  const version: Version = {
    version: (cur?.version ?? 0) + 1,
    source,
    canonical: v.value.canonical,
    applied_by: ctx.principal.user ?? ctx.principal.identity,
    applied_at: ctx.now,
    tests_passed: v.value.tests.passed,
    rollback_of: rollbackOf
  }
  const versions = [...n.versions, version].slice(-MAX_VERSIONS)
  return { ok: true, state: withNet(state, bump({ ...n, versions })), value: version }
}

export const NETWORK_OPS = new Set([
  "network.policy.apply",
  "network.policy.rollback",
  "network.device.join",
  "network.device.revoke",
  "network.machine.register",
  "network.machine.tag",
  "network.machine.remove",
  "network.reconcile.record",
  "network.install.revoked"
])

/** Tags whose membership changes between two lists. */
const changedTags = (a: ReadonlyArray<string>, b: ReadonlyArray<string>) => [...new Set([...a.filter((t) => !b.includes(t)), ...b.filter((t) => !a.includes(t))])]

export const reduceNetwork = <S extends TeamLike>(state: S, op: string, params: unknown, ctx: ReduceContext): R<S> => {
  const p = ctx.principal
  const n = net(state)
  if (!state.team) return reject("validation.invalid", "team not initialized")
  switch (op) {
    case "network.policy.apply": {
      if (!isAdmin(state, p)) return reject("auth.forbidden", "only team owners and admins change the network policy")
      const d = decodeParams<typeof NetworkPolicyApply.params.Type>(NetworkPolicyApply, params)
      if (!d.ok) return d
      const cur = currentVersion(n)?.version ?? null
      if (d.value.expected_version !== cur) return reject("version.conflict", `policy is at version ${cur ?? "none"}, not ${d.value.expected_version ?? "none"}`, { current: cur })
      return commitVersion(state, d.value.document, ctx, null)
    }
    case "network.policy.rollback": {
      if (!isAdmin(state, p)) return reject("auth.forbidden", "only team owners and admins change the network policy")
      const d = decodeParams<typeof NetworkPolicyRollback.params.Type>(NetworkPolicyRollback, params)
      if (!d.ok) return d
      const target = n.versions.find((v) => v.version === d.value.version)
      if (!target) return reject("selector.not_found", `version ${d.value.version} not found`)
      return commitVersion(state, target.source, ctx, target.version)
    }
    case "network.device.join": {
      const d = decodeParams<typeof NetworkDeviceJoin.params.Type>(NetworkDeviceJoin, params)
      if (!d.ok) return d
      if (!p.install || !p.user) return reject("auth.forbidden", "network.device.join needs an install token")
      const existing = n.devices[p.install]
      if (existing && existing.revoked_at === null && existing.wg_public_key === d.value.wg_public_key) return { ok: true, state, value: existing, changed: false }
      // The policy must give this user's devices some reachability, or a tunnel is pointless (spec "How a Mac joins" step 2).
      if (!grantsDevice(effectivePolicy(n), state, p.user, p.install)) return reject("network.no_access", "the network policy gives this user's devices no access")
      const device: Device = {
        install: p.install,
        user: p.user,
        wg_public_key: d.value.wg_public_key,
        joined_at: existing && existing.revoked_at === null ? existing.joined_at : ctx.now,
        revoked_at: null,
        status: "pending",
        tunnel: null
      }
      return { ok: true, state: withNet(state, bump({ ...n, devices: { ...n.devices, [p.install]: device } })), value: device }
    }
    case "network.device.revoke": {
      const d = decodeParams<typeof NetworkDeviceRevoke.params.Type>(NetworkDeviceRevoke, params)
      if (!d.ok) return d
      const dev = n.devices[d.value.install]
      if (!dev) return reject("selector.not_found", "device not found")
      if (dev.user !== p.user && !isAdmin(state, p)) return reject("auth.forbidden", "only the device's user or a team admin may revoke it")
      if (dev.revoked_at !== null) return { ok: true, state, value: dev, changed: false }
      const revoked: Device = { ...dev, revoked_at: ctx.now, status: "revoked", tunnel: null }
      return { ok: true, state: withNet(state, bump({ ...n, devices: { ...n.devices, [dev.install]: revoked } })), value: revoked }
    }
    case "network.machine.register": {
      if (!isAdmin(state, p)) return reject("auth.forbidden", "only team owners and admins register machines")
      const d = decodeParams<typeof NetworkMachineRegister.params.Type>(NetworkMachineRegister, params)
      if (!d.ok) return d
      const policy = effectivePolicy(n)
      const prev = n.machines[d.value.machine]
      for (const t of changedTags(prev?.tags ?? [], d.value.tags))
        if (!mayAssignTag(policy, directoryOf(state), { user: p.user! }, t)) return reject("tag.forbidden", `you may not assign tag:${t}`)
      if (d.value.owner_user && !state.members[d.value.owner_user]) return reject("validation.invalid", "owner_user is not a team member")
      const m: Machine = {
        id: d.value.machine,
        provider_id: d.value.provider_id,
        owner_user: d.value.owner_user,
        tags: [...new Set(d.value.tags)].sort(),
        classes: [...new Set(d.value.classes ?? [])].sort(),
        address: d.value.address ?? null
      }
      if (prev && JSON.stringify(prev) === JSON.stringify(m)) return { ok: true, state, value: m, changed: false }
      return { ok: true, state: withNet(state, bump({ ...n, machines: { ...n.machines, [m.id]: m } })), value: m }
    }
    case "network.machine.tag": {
      const d = decodeParams<typeof NetworkMachineTag.params.Type>(NetworkMachineTag, params)
      if (!d.ok) return d
      const prev = n.machines[d.value.machine]
      if (!prev) return reject("selector.not_found", "machine not found")
      const policy = effectivePolicy(n)
      const tags = [...new Set(d.value.tags)].sort()
      for (const t of changedTags(prev.tags, tags)) {
        if (!(t in policy.tagOwners)) return reject("tag.forbidden", `tag:${t} is not declared in tagOwners`)
        if (!p.user || !mayAssignTag(policy, directoryOf(state), { user: p.user }, t)) return reject("tag.forbidden", `you may not assign tag:${t}`)
      }
      if (JSON.stringify(prev.tags) === JSON.stringify(tags)) return { ok: true, state, value: prev, changed: false }
      const m: Machine = { ...prev, tags }
      return { ok: true, state: withNet(state, bump({ ...n, machines: { ...n.machines, [m.id]: m } })), value: m }
    }
    case "network.machine.remove": {
      if (!isAdmin(state, p)) return reject("auth.forbidden", "only team owners and admins remove machines")
      const d = decodeParams<typeof NetworkMachineRemove.params.Type>(NetworkMachineRemove, params)
      if (!d.ok) return d
      if (!n.machines[d.value.machine]) return reject("selector.not_found", "machine not found")
      const { [d.value.machine]: _gone, ...rest } = n.machines
      return { ok: true, state: withNet(state, bump({ ...n, machines: rest })), value: { machine: d.value.machine } }
    }
    case "network.install.revoked": {
      const install = (params as { install?: unknown })?.install
      const dev = typeof install === "string" ? n.devices[install] : undefined
      if (!dev || dev.revoked_at !== null) return { ok: true, state, value: null, changed: false }
      const revoked: Device = { ...dev, revoked_at: ctx.now, status: "revoked", tunnel: null }
      return { ok: true, state: withNet(state, bump({ ...n, devices: { ...n.devices, [dev.install]: revoked } })), value: { install: dev.install } }
    }
    case "network.reconcile.record": {
      const exit = Schema.decodeUnknownExit(ReconcileRecordParams)(params)
      if (exit._tag !== "Success") return reject("validation.invalid", "invalid reconcile record")
      const r = exit.value
      if (r.desired_seq < n.reconcile.applied_seq) return { ok: true, state, value: { stale: true }, changed: false }
      const tunnels = new Map(r.tunnels.map((t) => [t.install, t.tunnel]))
      const devices: Record<string, Device> = {}
      for (const [id, d] of Object.entries(n.devices)) {
        const t: Tunnel | undefined = tunnels.get(id)
        // A tunnel only counts for a live device; a revoked device stays revoked whatever the report says.
        if (d.revoked_at !== null) devices[id] = d
        else if (t) devices[id] = { ...d, status: "ready", tunnel: t }
        else devices[id] = r.converged && r.configured ? { ...d, status: "pending", tunnel: null } : d
      }
      const failures = r.actions.filter((a) => !a.ok).map((a) => `${a.op}: ${a.error ?? "failed"}`)
      const reconcile: ReconcileStatus = {
        desired_seq: n.reconcile.desired_seq,
        // Only a converged (or unconfigured) run settles a desired state; a failed one stays pending for the retry.
        applied_seq: r.converged || !r.configured ? Math.max(n.reconcile.applied_seq, r.desired_seq) : n.reconcile.applied_seq,
        vpc_id: r.vpc_id ?? n.reconcile.vpc_id,
        last: {
          at: r.started_at,
          ms: r.ms,
          converged: r.converged,
          configured: r.configured,
          actions: r.actions.length,
          failures,
          drift: r.drift,
          deferred: r.deferred,
          ...(r.foreign && r.foreign.length > 0 ? { foreign: r.foreign } : {}),
          ...(r.error ? { error: r.error } : {})
        }
      }
      return { ok: true, state: withNet(state, { ...n, devices, reconcile }), value: { applied_seq: reconcile.applied_seq } }
    }
    default:
      return reject("validation.invalid", `unknown op ${op}`)
  }
}

/**
 * Whether any rule would touch a device of `user`: compiled against today's
 * machines plus one probe machine per declared tag and one personal machine,
 * so a team with no machines yet can still join.
 */
const grantsDevice = (policy: Policy, state: TeamLike, user: string, install: string): boolean => {
  const dir = directoryOf(state)
  const probe: Directory = {
    ...dir,
    devices: [{ install, user }],
    machines: [...dir.machines, ...Object.keys(policy.tagOwners).map((t) => ({ id: `mach_probe_${t}`, tags: [t] })), { id: "mach_probe_self", owner_user: user, tags: [] }]
  }
  return compileNetwork(policy, probe).rules.some((r) => (r.src.kind === "device" && r.src.install === install) || (r.dst.kind === "device" && r.dst.install === install))
}

/** Read projections for TeamDO.read(). */
export const readNetwork = (state: TeamLike, op: string, params: unknown, principal: Principal): { ok: true; value: unknown } | { ok: false; code: string; message: string } => {
  const n = net(state)
  const q = (params ?? {}) as { version?: unknown; install?: unknown; document?: unknown }
  switch (op) {
    case "network.policy.get": {
      const cur = currentVersion(n)
      const v = typeof q.version === "number" ? n.versions.find((x) => x.version === q.version) : cur
      if (typeof q.version === "number" && !v) return { ok: false, code: "selector.not_found", message: `version ${q.version} not found` }
      const policy: Version = v ?? { version: 0, source: DEFAULT_POLICY, canonical: "", applied_by: "system", applied_at: 0, tests_passed: 0, rollback_of: null }
      return {
        ok: true,
        value: {
          policy,
          effective_default: !cur,
          versions: n.versions.map((x) => ({ version: x.version, applied_by: x.applied_by, applied_at: x.applied_at, rollback_of: x.rollback_of })),
          reconcile: n.reconcile
        }
      }
    }
    case "network.policy.preview": {
      if (!isAdmin(state, principal)) return { ok: false, code: "auth.forbidden", message: "only team owners and admins preview policy changes" }
      if (typeof q.document !== "string") return { ok: false, code: "validation.invalid", message: "document must be a string" }
      const cur = currentVersion(n)
      const r = previewPolicy(cur ? cur.source : null, q.document, directoryOf(state))
      return { ok: true, value: r.ok ? { ok: true, canonical: r.canonical, diff: r.diff, compiled: r.compiled, notes: r.notes } : { ok: false, issues: r.issues } }
    }
    case "network.device.get": {
      const all = Object.values(n.devices)
      const mine = isAdmin(state, principal) ? all : all.filter((d) => d.user === principal.user)
      const devices = typeof q.install === "string" ? mine.filter((d) => d.install === q.install) : principal.kind === "install" && !isAdmin(state, principal) ? mine.filter((d) => d.install === principal.install) : mine
      return { ok: true, value: { devices } }
    }
    default:
      return { ok: false, code: "validation.invalid", message: `unknown read ${op}` }
  }
}
