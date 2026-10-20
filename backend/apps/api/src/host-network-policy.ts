import type { Principal } from "@cmux/ownership"
import { HostNetworkPolicy, HostNetworkPolicyView, NativeDeviceId, WgPublicKey } from "@cmux/protocol"
import { Schema } from "effect"
import { admit, decodeParams } from "./domains/common.ts"
import type { Http } from "./team-domain-external.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"
import type { ReadResult } from "./owner-do.ts"
import { networkOrigin, verifyNetworkIdentity } from "./network-policy-read.ts"
import { boundedIdentities, pointUnique, sameCandidate, sameNetwork, digest, hostStamp, identityMatches, liveHost, networkHosts, ownHost, peerAuthorityVersion, pointOf, type NetworkIdentity, type NetworkHost, type PeerDeps } from "./host-network-peers.ts"

interface Deps extends PeerDeps { project: string; origin(): string | undefined; tenant(): Promise<VmApiTenant | null>; revision(): string; http: Http }
type Allow = { protocol: "tcp" | "udp" | "icmp" | "any"; port?: number }
type NativePeer = { deviceId: string; wgPublicKey: string; installPublicKey: string; inbound: Allow[]; outbound: Allow[] }
const allows = (value: unknown): value is Allow[] => Array.isArray(value) && value.length <= 4096 && value.every((v: unknown) => {
  if (!v || typeof v !== "object" || Array.isArray(v)) return false
  const p = v as { protocol?: unknown; port?: unknown }
  return ["tcp", "udp", "any", "icmp"].includes(String(p.protocol))
    && (p.port === undefined || ((p.protocol === "tcp" || p.protocol === "udp") && Number.isInteger(p.port) && Number(p.port) > 0 && Number(p.port) <= 65535))
})
const peersOf = (policy: Record<string, unknown>, self: NetworkHost, point: string): NativePeer[] | null => {
  if (!Array.isArray(policy.peers) || policy.peers.length > 128 || !Number.isSafeInteger(policy.aclVersion) || Number(policy.aclVersion) < 0
    || typeof policy.policyDigest !== "string" || !/^[0-9a-f]{64}$/.test(policy.policyDigest)) return null
  const devices = new Set([self.network!.device]), keys = new Set([self.wg_public_key!]), points = new Set([point]), peers: NativePeer[] = []
  for (const value of policy.peers as unknown[]) {
    if (!value || typeof value !== "object" || Array.isArray(value)) return null
    const p = value as Record<string, unknown>
    if (!Schema.is(NativeDeviceId)(p.deviceId) || !Schema.is(WgPublicKey)(p.wgPublicKey) || typeof p.installPublicKey !== "string"
      || !/^B[A-Za-z0-9+/]{86}=$/.test(p.installPublicKey) || !allows(p.inbound) || !allows(p.outbound)
      || devices.has(p.deviceId) || keys.has(p.wgPublicKey) || points.has(p.installPublicKey)) return null
    devices.add(p.deviceId); keys.add(p.wgPublicKey); points.add(p.installPublicKey)
    peers.push({ deviceId: p.deviceId, wgPublicKey: p.wgPublicKey, installPublicKey: p.installPublicKey, inbound: p.inbound, outbound: p.outbound })
  }
  return peers
}

/** A fresh identity projection, not a dial token or permission to activate a listener. */
export const hostNetworkPolicy = async (d: Deps, p: Principal, params: unknown): Promise<ReadResult> => {
  const checkedAt = d.now()
  const fail = (code: string, message: string): ReadResult => ({ ok: false, code, message })
  const forbidden = () => fail("auth.forbidden", "the current host network identity could not be verified")
  const unavailable = () => fail("owner.unreachable", "the current host network policy is unavailable")
  const admission = admit("cloud:TeamDO", HostNetworkPolicy.name, p, () => p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined, d.now())
  if (admission) return { ...admission, ok: false }
  const decoded = decodeParams<typeof HostNetworkPolicy.params.Type>(HostNetworkPolicy, params)
  if (!decoded.ok) return fail("validation.invalid", "invalid host network policy request")
  const host = ownHost(d, p, decoded.value.host), origin = networkOrigin(d.origin())
  if (!host?.network) return forbidden()
  if (!origin) return unavailable()
  try {
    const [tenant, own] = await Promise.all([d.tenant(), d.identity(p.user!, p.install!, p.grant!)])
    if (tenant?.team !== d.team || tenant.project !== d.project || tenant.tenant !== host.network.tenant || !identityMatches(host, own, d.now())) return forbidden()
    const point = pointOf(own)!, original = hostStamp(d, host)
    const read = await verifyNetworkIdentity(d.http, origin, host.kind === "server" ? "server" : "device",
      { ...host.network, wg: host.wg_public_key!, point }, decoded.value.proof, d.now())
    if (!read.ok) return read.code === "selector.not_found" ? forbidden() : read
    const native = peersOf(read.policy, host, point), all = networkHosts(d)
    if (!native || !all) return unavailable()
    const candidates = all.filter((h) => sameNetwork(host, h) && liveHost(d, h))
    if (candidates.filter((h) => sameCandidate(host, h)).length !== 1) return forbidden()
    const graph = digest(candidates.map((h) => hostStamp(d, h)))
    const first = await boundedIdentities(d, candidates)
    if (!pointUnique(d, candidates, first, point)) return forbidden()
    const selected: Array<{ native: NativePeer; host: NetworkHost; stamp: string }> = []
    for (const peer of native) {
      const matches = candidates.filter((h) => h.network?.device === peer.deviceId || h.wg_public_key === peer.wgPublicKey)
      if (matches.length !== 1) continue
      const h = matches[0]!
      if (h.network?.device !== peer.deviceId || h.wg_public_key !== peer.wgPublicKey
        || candidates.filter((other) => sameCandidate(h, other)).length !== 1) continue
      selected.push({ native: peer, host: h, stamp: hostStamp(d, h) })
    }
    const initial = selected.filter(({ native, host }) => identityMatches(host, first.get(host.id) ?? null, d.now()) && pointOf(first.get(host.id) ?? null) === native.installPublicKey && pointUnique(d, candidates, first, native.installPublicKey))
    const [currentTenant, currentOwn, second] = await Promise.all([d.tenant(), d.identity(p.user!, p.install!, p.grant!), boundedIdentities(d, candidates)])
    const current = ownHost(d, p, host.id), currentAll = networkHosts(d)
    if (networkOrigin(d.origin()) !== origin || currentTenant?.team !== d.team || currentTenant.project !== d.project || currentTenant.tenant !== tenant.tenant
      || !current || hostStamp(d, current) !== original || !identityMatches(current, currentOwn, d.now()) || currentOwn.authority_version !== own.authority_version || pointOf(currentOwn) !== point || !currentAll) return forbidden()
    const liveCandidates = currentAll.filter((h) => sameNetwork(current, h) && liveHost(d, h))
    if (digest(liveCandidates.map((h) => hostStamp(d, h))) !== graph || !pointUnique(d, liveCandidates, second, point)) return forbidden()
    const now = d.now()
    let expires = Math.min(checkedAt + 30_000, currentOwn.expires_at ?? Infinity, p.expires_at ?? Infinity)
    const peers = initial.flatMap(({ native, host: old, stamp }) => {
      const identity = second.get(old.id) ?? null, live = currentAll.find((h) => h.id === old.id)
      if (!live || !liveHost(d, live) || hostStamp(d, live) !== stamp || currentAll.filter((h) => sameNetwork(current, h) && liveHost(d, h) && sameCandidate(live, h)).length !== 1
        || !pointUnique(d, liveCandidates, second, native.installPublicKey) || !identityMatches(live, identity, now) || identity.authority_version !== first.get(old.id)?.authority_version || pointOf(identity) !== native.installPublicKey) return []
      expires = Math.min(expires, identity.expires_at ?? Infinity)
      return [{ host: live.id, user: live.owner_user!, install: live.enrolled_by, device: native.deviceId, wg_public_key: native.wgPublicKey, install_public_key: native.installPublicKey,
        authority_version: peerAuthorityVersion(d, live, identity), inbound: native.inbound.map(({ protocol, port }) => ({ protocol, ...(port === undefined ? {} : { port }) })), outbound: native.outbound.map(({ protocol, port }) => ({ protocol, ...(port === undefined ? {} : { port }) })) }]
    })
    if (expires <= now) return forbidden()
    const value = { schema_version: 1, host: current.id, user: current.owner_user!, install: current.enrolled_by, origin, checked_at: checkedAt, team: d.team, tenant: tenant.tenant, mesh: current.network!.mesh, device: current.network!.device,
      wg_public_key: current.wg_public_key!, install_public_key: point, expires_at: expires, acl_version: Number(read.policy.aclVersion), policy_digest: read.policy.policyDigest,
      authority_version: digest(["cmux-host-network-v1", original, currentOwn.authority_version, read.policy.aclVersion, read.policy.policyDigest, peers]), peers }
    return Schema.is(HostNetworkPolicyView)(value) ? { ok: true, value, revision: d.revision() } : unavailable()
  } catch { return unavailable() }
}
