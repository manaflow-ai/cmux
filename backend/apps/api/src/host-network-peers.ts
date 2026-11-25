import { createHash } from "node:crypto"
import type { Principal, RowReader } from "@cmux/ownership"
import type { Host } from "@cmux/protocol"
import type { TeamState } from "./domains/team.ts"
import { can, hostOf, listHosts } from "./domains/team-members.ts"
import { serverPlacementActive } from "./domains/team-servers.ts"
import { teamAuthorityVersion } from "./domains/team-authority.ts"
import { currentPolicy } from "./domains/team-policy.ts"
import { roleOf } from "./domains/team-members.ts"
import { installPublicPoint } from "./install-public-point.ts"

export type NetworkHost = typeof Host.Type
export interface NetworkIdentity { key: JsonWebKey; kind: string; expires_at: number | null; authority_version: string; op_classes: ReadonlyArray<string> }
export interface PeerDeps { team: string; state: () => TeamState; rows: RowReader | undefined; identity(user: string, install: string, grant: string): Promise<NetworkIdentity | null>; identities(user: string, entries: ReadonlyArray<{ install: string; grant: string }>): Promise<ReadonlyArray<NetworkIdentity | null>>; now(): number }
export const digest = (value: unknown): string => createHash("sha256").update(JSON.stringify(value)).digest("hex")
export const pointOf = (identity: NetworkIdentity | null): string | null => { try { return identity ? installPublicPoint(identity.key) : null } catch { return null } }

/** Read all bounded candidates so a second mapping cannot hide past a page boundary. */
export const networkHosts = (d: PeerDeps): NetworkHost[] | null => {
  const found: NetworkHost[] = []; let after: string | undefined
  for (let page = 0; page < 32; page++) {
    const value = listHosts(d.state(), d.rows, after, 128)
    found.push(...value.items)
    if (!value.next) return found
    after = value.next
  }
  return null
}
export const liveHost = (d: PeerDeps, host: NetworkHost): boolean => {
  const state = d.state()
  return state.team?.id === d.team && state.team.deleted_at === undefined && !!host.owner_user && !host.orphaned
    && !state.server_revocations?.[host.enrolled_by] && can(state, d.rows, host.owner_user, "team.resources")
    && host.network?.state === "confirmed" && !!host.network.install_grant && !!host.wg_public_key
    && (host.kind !== "server" || serverPlacementActive(state, d.rows, host.id, host.enrolled_by))
}
export const ownHost = (d: PeerDeps, p: Principal, id: string): NetworkHost | null => {
  if (p.kind !== "install" || p.agent !== undefined || !p.install || !p.user || !p.grant || p.team !== d.team) return null
  const host = hostOf(d.state(), d.rows, id)
  return host && liveHost(d, host) && host.enrolled_by === p.install && host.owner_user === p.user
    && host.network?.state === "confirmed" && host.network.install_grant === p.grant
    && (host.kind === "server" ? p.install_kind === "daemon" : ["mac", "ios", "cli"].includes(p.install_kind ?? "")) ? host : null
}
export const hostStamp = (d: Pick<PeerDeps, "state" | "rows" | "team">, host: NetworkHost): string => {
  const state = d.state(), role = roleOf(state, d.rows, host.owner_user)
  return digest([host.id, host.owner_user, host.enrolled_by, host.kind, host.network, host.wg_public_key,
    state.team && role ? teamAuthorityVersion(d.team, host.owner_user!, role, state.team.kind, currentPolicy(state).version, d.rows) : null])
}
/** The same install/host incarnation is used in peer views and signed dial credentials. */
export const peerAuthorityVersion = (d: Pick<PeerDeps, "state" | "rows" | "team">, host: NetworkHost, identity: NetworkIdentity): string =>
  digest(["cmux-network-peer-v1", hostStamp(d, host), identity.authority_version])
export const identityMatches = (host: NetworkHost, identity: NetworkIdentity | null, now: number): identity is NetworkIdentity =>
  identity !== null && (identity.expires_at === null || identity.expires_at > now) && /^[0-9a-f]{64}$/.test(identity.authority_version)
    && (host.kind === "server" ? identity.kind === "daemon" : ["mac", "ios", "cli"].includes(identity.kind)) && pointOf(identity) !== null

export const sameNetwork = (a: NetworkHost, b: NetworkHost): boolean => a.network?.tenant === b.network?.tenant && a.network?.mesh === b.network?.mesh
export const sameCandidate = (a: NetworkHost, b: NetworkHost): boolean => a.network?.device === b.network?.device || a.wg_public_key === b.wg_public_key || a.enrolled_by === b.enrolled_by
export const boundedIdentities = async (d: PeerDeps, hosts: NetworkHost[], deadline = Infinity) => {
  const found = new Map<string, NetworkIdentity | null>(), owners = new Map<string, NetworkHost[]>()
  for (const host of hosts) if (host.owner_user) owners.set(host.owner_user, [...(owners.get(host.owner_user) ?? []), host])
  const chunks = [...owners].flatMap(([user, values]) => Array.from({ length: Math.ceil(values.length / 128) }, (_, index) => ({ user, hosts: values.slice(index * 128, (index + 1) * 128) })))
  for (let offset = 0; offset < chunks.length; offset += 16) {
    if (d.now() >= deadline) throw new Error("identity snapshot deadline exceeded")
    await Promise.all(chunks.slice(offset, offset + 16).map(async ({ user, hosts }) => {
      const entries = hosts.map((h) => ({ install: h.enrolled_by, grant: h.network?.state === "confirmed" ? h.network.install_grant ?? "" : "" }))
      const values = await d.identities(user, entries)
      if (values.length !== hosts.length) throw new Error("unavailable identity snapshot")
      hosts.forEach((h, i) => found.set(h.id, values[i] ?? null))
    }))
  }
  return found
}
/**
 * The final per-owner read of the given hosts' identities, every owner at once and nothing awaited after it.
 * A change that lands while an earlier snapshot or another owner's batch was pending is seen here; what
 * remains is the window inside this one concurrent round, bounded by the answer's lease.
 */
export const fenceIdentities = async (d: PeerDeps, hosts: NetworkHost[], deadline: number) => {
  if (hosts.length > 128) throw new Error("identity fence is bounded")
  const found = new Map<string, NetworkIdentity | null>(), owners = new Map<string, NetworkHost[]>()
  for (const host of hosts) if (host.owner_user) owners.set(host.owner_user, [...(owners.get(host.owner_user) ?? []), host])
  if (d.now() >= deadline) throw new Error("identity snapshot deadline exceeded")
  await Promise.all([...owners].map(async ([user, values]) => {
    const entries = values.map((h) => ({ install: h.enrolled_by, grant: h.network?.state === "confirmed" ? h.network.install_grant ?? "" : "" }))
    const answers = await d.identities(user, entries)
    if (answers.length !== values.length) throw new Error("unavailable identity snapshot")
    values.forEach((h, i) => found.set(h.id, answers[i] ?? null))
  }))
  return found
}
export const pointUnique = (d: PeerDeps, hosts: NetworkHost[], identities: Map<string, NetworkIdentity | null>, point: string): boolean =>
  hosts.filter((h) => identityMatches(h, identities.get(h.id) ?? null, d.now()) && pointOf(identities.get(h.id) ?? null) === point).length === 1


/** The exact client/grant classes accepted by the Cloud token issuer and receiver projection. */
export const cloudClientIdentity = (host: NetworkHost, own: NetworkIdentity | null, now: number): own is NetworkIdentity =>
  host.kind !== "server" && identityMatches(host, own, now) && ["mac", "ios", "cli"].includes(own.kind)
    && Array.isArray(own.op_classes) && (own.op_classes.includes("execute") || own.op_classes.includes("cloud-link"))
