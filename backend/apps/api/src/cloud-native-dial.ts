import type { Principal } from "@cmux/ownership"
import { CloudVmNetwork, ServerNetworkProof } from "@cmux/protocol"
import { Schema } from "effect"
import { can, hostByInstall } from "./domains/team-members.ts"
import { cloudClientIdentity, hostStamp, peerAuthorityVersion, pointOf, type NetworkHost, type NetworkIdentity } from "./host-network-peers.ts"
import { networkOrigin, verifyNetworkIdentity, type NetworkIdentityDeps } from "./network-policy-read.ts"

export type NativeDialDeps = Omit<NetworkIdentityDeps, "stream" | "submitSystem" | "key"> & {
  readonly allowed: () => ReadonlyArray<string>
  readonly identity: (user: string, install: string, grant: string) => Promise<NetworkIdentity | null>
}
export interface NativeDialTarget { readonly vm: string; readonly origin: string; readonly network: typeof CloudVmNetwork.Type }
export interface NativeDialPermit {
  readonly team: string
  readonly user: string
  readonly install: string
  readonly grant: string
  readonly host: string
  readonly tenant: string
  readonly mesh: string
  readonly device: string
  readonly wg: string
  readonly point: string
  readonly origin: string
  readonly services: ReadonlyArray<string>
  readonly aclVersion: number
  readonly policyDigest: string
  readonly authorityVersion: string
  readonly grantExpiresAt: number | null
}
type Failure = { readonly ok: false; readonly code: string; readonly message: string }
export type NativeDialReply = { readonly ok: true; readonly permit: NativeDialPermit } | Failure
const forbidden = (): Failure => ({ ok: false, code: "auth.forbidden", message: "the current client network policy does not authorize this dial" })
const dialIdentity = (host: NetworkHost, own: NetworkIdentity | null, p: Principal, now: number): own is NetworkIdentity =>
  cloudClientIdentity(host, own, now) && (p.expires_at === undefined || p.expires_at > now)
    && (p.install_authority === undefined || p.install_authority === own.authority_version)

/** A historical confirmation is a locator. Current grant, key, membership and policy decide access. */
const currentBinding = (d: NativeDialDeps, p: Principal) => {
  const state = d.state()
  if (p.kind !== "install" || p.agent !== undefined || !p.user || !p.install || !p.grant || p.team !== d.team
    || !["mac", "ios", "cli"].includes(p.install_kind ?? "") || state.team?.id !== d.team
    || state.team.deleted_at !== undefined || state.server_revocations?.[p.install]
    || !can(state, d.rows, p.user, "team.resources")) return null
  const host = hostByInstall(state, d.rows, p.install)
  if (!host || host.kind === "server" || host.orphaned || host.owner_user !== p.user || host.enrolled_by !== p.install
    || !host.wg_public_key || host.network?.state !== "confirmed" || host.network.install_grant !== p.grant) return null
  return host
}

const servicesCurrent = (d: NativeDialDeps, services: ReadonlyArray<string>): boolean => {
  const allowed = d.allowed()
  return services.length > 0 && services.every((service) => ["daemon", "ssh"].includes(service) && allowed.includes(service))
    && (!services.includes("daemon") || allowed.includes("ssh"))
}

/** Reject unsupported/ambiguous projections instead of inferring a service from transport reachability. */
const vmServices = (policy: Record<string, unknown>, target: NativeDialTarget, services: ReadonlyArray<string>): boolean => {
  if (!Number.isSafeInteger(policy.aclVersion) || (policy.aclVersion as number) < 0
    || typeof policy.policyDigest !== "string" || !/^[0-9a-f]{64}$/.test(policy.policyDigest) || !Array.isArray(policy.vms)) return false
  const entries = policy.vms.filter((entry: unknown) => entry !== null && typeof entry === "object" && (entry as { id?: unknown }).id === target.vm)
  if (entries.length !== 1) return false
  const vm = entries[0] as Record<string, unknown>
  if (vm.kind !== "vm" || vm.address !== target.network.ipv4 || !Array.isArray(vm.allow) || vm.allow.length > 4096) return false
  const available = vmRuleServices(vm.allow)
  return available !== null && services.every((service) => available.includes(service))
}

/** Service rules shared by the signed dial issuer and VM receiving policy. */
export const vmRuleServices = (allow: ReadonlyArray<unknown>): string[] | null => {
  const ports = new Set<number>()
  let anyTcp = false
  for (const entry of allow) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null
    const rule = entry as { protocol?: unknown; port?: unknown }
    if (!["tcp", "udp", "icmp", "any"].includes(String(rule.protocol))
      || (rule.port !== undefined && (!Number.isInteger(rule.port) || Number(rule.port) < 1 || Number(rule.port) > 65535))
      || ((rule.protocol === "any" || rule.protocol === "icmp") && rule.port !== undefined)) return null
    if (rule.protocol !== "tcp" && rule.protocol !== "any") continue
    if (rule.port === undefined) anyTcp = true
    else ports.add(Number(rule.port))
  }
  const covers = (port: number) => anyTcp || ports.has(port)
  return ["daemon", "ssh"].filter((service) => service === "ssh" ? covers(22) : covers(22) && covers(4100))
}

/** A fresh, one-use device proof joins this install to its own Native VM permissions. */
export const authorizeNativeDial = async (
  d: NativeDialDeps, p: Principal, target: NativeDialTarget, proof: unknown, services: ReadonlyArray<string>
): Promise<NativeDialReply> => {
  const host = currentBinding(d, p), origin = networkOrigin(d.origin)
  if (!host?.network || !origin || target.origin !== origin || !servicesCurrent(d, services) || !Schema.is(ServerNetworkProof)(proof)
    || !Schema.is(CloudVmNetwork)(target.network) || !/^vm_[a-z0-9]{26}$/.test(target.vm)
    || target.network.tenant !== host.network.tenant || target.network.mesh !== host.network.mesh) return forbidden()
  // The host and membership stamp is taken before the first await; a change during any read never becomes the baseline.
  const stamp = hostStamp(d, host)
  try {
    const [tenant, own] = await Promise.all([d.tenant(), d.identity(p.user!, p.install!, p.grant!)])
    const point = pointOf(own), current = currentBinding(d, p)
    if (!point || !current || current.id !== host.id || hostStamp(d, current) !== stamp || !dialIdentity(current, own, p, d.now())
      || tenant?.team !== d.team || tenant.project !== d.project || tenant.tenant !== target.network.tenant) return forbidden()
    const authorityVersion = peerAuthorityVersion(d, host, own)
    const identity = { ...host.network, wg: host.wg_public_key!, point }
    const read = await verifyNetworkIdentity(d.http, origin, "device", identity, proof, d.now())
    if (!read.ok) return read
    if (!vmServices(read.policy, target, services)) return forbidden()
    const permit: NativeDialPermit = {
      team: d.team, user: p.user!, install: p.install!, grant: p.grant!, host: host.id,
      tenant: identity.tenant, mesh: identity.mesh, device: identity.device, wg: identity.wg, point, origin,
      services: [...services], aclVersion: read.policy.aclVersion as number, policyDigest: read.policy.policyDigest as string,
      authorityVersion, grantExpiresAt: own.expires_at
    }
    return await recheckNativeDial(d, p, permit) ? { ok: true, permit } : forbidden()
  } catch { return { ok: false, code: "owner.unreachable", message: "current network authorization is unavailable" } }
}

/** Recheck after token signing without replaying the consumed Native nonce. No I/O follows the final local checks. */
export const recheckNativeDial = async (d: NativeDialDeps, p: Principal, permit: NativeDialPermit): Promise<boolean> => {
  if (permit.team !== d.team || permit.user !== p.user || permit.install !== p.install || permit.grant !== p.grant) return false
  try {
    // The identity read is the last await: an install change during the tenant lookup is always seen.
    const tenant = await d.tenant()
    const own = await d.identity(permit.user, permit.install, permit.grant)
    const current = currentBinding(d, p)
    return !!current && dialIdentity(current, own, p, d.now()) && peerAuthorityVersion(d, current, own) === permit.authorityVersion
      && own.expires_at === permit.grantExpiresAt && pointOf(own) === permit.point && tenant?.team === d.team && tenant.project === d.project && tenant.tenant === permit.tenant
      && networkOrigin(d.origin) === permit.origin && servicesCurrent(d, permit.services) && current?.id === permit.host
      && current.wg_public_key === permit.wg && current.network?.tenant === permit.tenant && current.network.mesh === permit.mesh && current.network.device === permit.device
  } catch { return false }
}
