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
export interface NetworkIdentity { key: JsonWebKey; kind: string; expires_at: number | null; authority_version: string }
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
  if (p.kind !== "install" || p.agent || !p.install || !p.user || !p.grant || p.team !== d.team) return null
  const host = hostOf(d.state(), d.rows, id)
  return host && liveHost(d, host) && host.enrolled_by === p.install && host.owner_user === p.user
    && host.network?.state === "confirmed" && host.network.install_grant === p.grant
    && (host.kind === "server" ? p.install_kind === "daemon" : ["mac", "ios", "cli"].includes(p.install_kind ?? "")) ? host : null
}
export const hostStamp = (d: PeerDeps, host: NetworkHost): string => {
  const state = d.state(), role = roleOf(state, d.rows, host.owner_user)
  return digest([host.id, host.owner_user, host.enrolled_by, host.kind, host.network, host.wg_public_key,
    state.team && role ? teamAuthorityVersion(d.team, host.owner_user!, role, state.team.kind, currentPolicy(state).version, d.rows) : null])
}
export const identityMatches = (host: NetworkHost, identity: NetworkIdentity | null, now: number): identity is NetworkIdentity =>
  identity !== null && (identity.expires_at === null || identity.expires_at > now) && /^[0-9a-f]{64}$/.test(identity.authority_version)
    && (host.kind === "server" ? identity.kind === "daemon" : ["mac", "ios", "cli"].includes(identity.kind)) && pointOf(identity) !== null
