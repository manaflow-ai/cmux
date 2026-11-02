import type { CloudVmReceiverPeer } from "@cmux/protocol"
import { personalTeamIdFor } from "./domains/user.ts"
import { boundedIdentities, cloudClientIdentity, digest, fenceIdentities, hostStamp, liveHost, networkHosts, peerAuthorityVersion, pointOf, pointUnique, sameCandidate, type PeerDeps } from "./host-network-peers.ts"
import { vmRuleServices } from "./cloud-native-dial.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"
import type { NativeVmReceiverPolicy } from "./cloud-vm-receiver-native.ts"
import { networkOrigin } from "./network-policy-read.ts"
import { can, roleOf } from "./domains/team-members.ts"
import { teamAuthorityVersion } from "./domains/team-authority.ts"
import { currentPolicy } from "./domains/team-policy.ts"

export interface VmReceiverPeerTarget { creator: string; origin: string; deadline: number; policy: NativeVmReceiverPolicy }
interface Deps extends PeerDeps { project: string; origin(): string | undefined; tenant(): Promise<VmApiTenant | null>; allowed(): ReadonlyArray<string> }
export interface VmReceiverPeers { peers: Array<typeof CloudVmReceiverPeer.Type>; expires_at: number; authority_version: string }

/** TeamDO's bounded current authority join; a Native peer alone never grants a Cloud service. */
export const vmReceiverPeers = async (d: Deps, target: VmReceiverPeerTarget): Promise<VmReceiverPeers | null> => {
  if (!Number.isSafeInteger(target.deadline) || d.now() >= target.deadline || target.deadline > d.now() + 15_000) return null
  const creator = () => {
    const state = d.state(), role = roleOf(state, d.rows, target.creator)
    return state.team?.id === d.team && state.team.deleted_at === undefined && role && can(state, d.rows, target.creator, "team.resources")
      ? teamAuthorityVersion(d.team, target.creator, role, state.team.kind, currentPolicy(state).version, d.rows) : null
  }
  // The creator's membership baseline is taken before the first await; a change during the tenant read never becomes it.
  const baseline = creator()
  if (baseline === null) return null
  const policy = target.policy, tenant = await d.tenant(), all = networkHosts(d)
  if (d.now() >= target.deadline || creator() !== baseline || networkOrigin(d.origin()) !== target.origin || tenant?.team !== d.team || tenant.project !== d.project || tenant.tenant !== policy.tenantId || !all) return null
  const inMesh = (h: (typeof all)[number]) => h.network?.tenant === policy.tenantId && h.network?.mesh === policy.meshId
  const candidates = all.filter((h) => inMesh(h) && liveHost(d, h))
  const stamp = () => digest([creator(), d.origin(), d.allowed(), networkHosts(d)?.filter((h) => inMesh(h) && liveHost(d, h)).map((h) => hostStamp(d, h))])
  const graph = stamp(), first = await boundedIdentities(d, candidates, target.deadline)
  if (d.now() >= target.deadline) return null
  const currentTenant = await d.tenant()
  if (d.now() >= target.deadline || currentTenant?.team !== d.team || currentTenant.project !== d.project || currentTenant.tenant !== tenant.tenant || stamp() !== graph) return null
  const second = await boundedIdentities(d, candidates, target.deadline)
  if (d.now() >= target.deadline || stamp() !== graph) return null
  const selected: Array<{ native: (typeof policy.peers)[number]; host: (typeof candidates)[number] }> = []
  for (const native of policy.peers) {
    const matches = candidates.filter((h) => h.network?.device === native.deviceId || h.wg_public_key === native.wgPublicKey)
    if (matches.length !== 1) continue
    const host = matches[0]!, identity = second.get(host.id) ?? null
    if (host.network?.device !== native.deviceId || host.wg_public_key !== native.wgPublicKey || candidates.filter((h) => sameCandidate(host, h)).length !== 1
      || !cloudClientIdentity(host, identity, d.now()) || identity.authority_version !== first.get(host.id)?.authority_version
      || pointOf(identity) !== native.installPublicKey || !pointUnique(d, candidates, first, native.installPublicKey) || !pointUnique(d, candidates, second, native.installPublicKey)
      || (d.team === personalTeamIdFor(target.creator) && host.owner_user !== target.creator)) continue
    selected.push({ native, host })
  }
  // The selected peers' owners are read once more, all at once, as the last await (policy.peers is at most 128).
  const final = await fenceIdentities(d, selected.map(({ host }) => host), target.deadline)
  if (d.now() >= target.deadline || stamp() !== graph || creator() !== baseline) return null
  const now = d.now(), allowed = d.allowed(), peers: VmReceiverPeers["peers"] = []
  let expires = policy.expiresAt
  for (const { native, host } of selected) {
    const identity = final.get(host.id) ?? null
    if (!cloudClientIdentity(host, identity, now) || identity.authority_version !== first.get(host.id)?.authority_version || pointOf(identity) !== native.installPublicKey) continue
    const rules = vmRuleServices(native.allow)
    const services = rules?.filter((s) => allowed.includes(s) && (s !== "daemon" || allowed.includes("ssh"))) as Array<"daemon" | "ssh"> | undefined
    if (!services?.length) continue
    expires = Math.min(expires, identity.expires_at ?? Infinity)
    peers.push({ host: host.id, user: host.owner_user!, install: host.enrolled_by, device: native.deviceId,
      wg_public_key: native.wgPublicKey, install_public_key: native.installPublicKey, authority_version: peerAuthorityVersion(d, host, identity), services })
  }
  return { peers, expires_at: expires, authority_version: digest(["cmux-cloud-vm-peers-v1", graph, peers]) }
}
