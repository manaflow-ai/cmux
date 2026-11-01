import type { Principal } from "@cmux/ownership"
import { NativeMeshId } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { can, roleOf } from "./domains/team-members.ts"
import { teamAuthorityVersion } from "./domains/team-authority.ts"
import { currentPolicy } from "./domains/team-policy.ts"
import { installPublicPoint } from "./install-public-point.ts"
import type { NetworkIdentityView } from "./user-do.ts"
import type { NetworkIdentityDeps } from "./network-policy-read.ts"
import { readNetworkMesh } from "./network-mesh-read.ts"
import type { ReadResult } from "./owner-do.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

type Deps = Omit<NetworkIdentityDeps, "origin" | "stream" | "submitSystem" | "key"> & {
  readonly connection: () => VmApiConnection | null
  readonly revision: () => string
  /** UserDO readIdentity: the client's key and install authority version under its live read grant. */
  readonly identity: (user: string, install: string, grant: string) => Promise<NetworkIdentityView | null>
}
/** The platform serves this read on its own route (no cloud catalog op); TeamDO keeps the owner checks. */
const Params = Schema.Struct({ mesh: Schema.optionalKey(NativeMeshId) })
const pointOf = (identity: NetworkIdentityView | null): string | null => { try { return identity ? installPublicPoint(identity.key) : null } catch { return null } }
/** The caller's install incarnation plus its team membership incarnation: an A to B to A change in either never matches. */
const authorityOf = (d: Deps, p: Principal, identity: NetworkIdentityView | null): string | null => {
  const state = d.state(), role = roleOf(state, d.rows, p.user)
  if (!identity || !state.team || !role || !/^[0-9a-f]{64}$/.test(identity.authority_version) || !["mac", "ios", "cli"].includes(identity.kind)
    || (p.install_authority !== undefined && p.install_authority !== identity.authority_version)) return null
  return `${identity.authority_version}:${teamAuthorityVersion(d.team, p.user!, role, state.team.kind, currentPolicy(state).version, d.rows)}`
}
const tenantMatches = (d: Deps, t: VmApiTenant | null): t is VmApiTenant => t?.team === d.team && t.project === d.project
const clientMayRead = (d: Deps, p: Principal): boolean => {
  const state = d.state()
  return p.kind === "install" && !p.agent && ["mac", "ios", "cli"].includes(p.install_kind ?? "") && p.team === d.team
    && !!p.user && !!p.install && !!p.grant && state.team?.id === d.team && state.team.deleted_at === undefined
    && !state.server_revocations?.[p.install] && can(state, d.rows, p.user, "team.resources")
}

/** Read-only routing discovery. Native ownership and current owner authorization must both agree. */
export const hostNetworkTarget = async (d: Deps, p: Principal, params: unknown): Promise<ReadResult> => {
  const fail = (code: string, message: string): ReadResult => ({ ok: false, code, message })
  const unavailable = () => fail("owner.unreachable", "network target discovery is unavailable")
  // The caller resolved the install's live grant classes; the identity read below rechecks the grant itself.
  if (!p.grant_classes?.includes("read") || (p.expires_at !== undefined && p.expires_at <= d.now())) return fail("auth.forbidden", "an active client install with the read grant is required")
  const decoded = Schema.decodeUnknownExit(Params)(params ?? {}, { onExcessProperty: "error" })
  if (!Exit.isSuccess(decoded)) return fail("validation.invalid", "invalid network target selector")
  if (!clientMayRead(d, p)) return fail("auth.forbidden", "only an active client may discover its team network")
  const connection = d.connection()
  if (!connection) return unavailable()
  try {
    const [target, own] = await Promise.all([d.tenant(), d.identity(p.user!, p.install!, p.grant!)])
    const point = pointOf(own), authority = authorityOf(d, p, own)
    if (!tenantMatches(d, target) || !point || !authority) return fail("auth.forbidden", "the client network owner could not be verified")
    const read = await readNetworkMesh(d.http, connection, target.tenant, decoded.value.mesh)
    const result: ReadResult = read.ok ? { ok: true, value: { team: d.team, tenant: target.tenant, project: target.project, origin: connection.origin, ...read.value }, revision: "" } : read
    const [currentTarget, currentOwn] = await Promise.all([d.tenant(), d.identity(p.user!, p.install!, p.grant!)])
    const currentConnection = d.connection()
    // No await between final live membership/authority/config checks and returning metadata.
    if (!tenantMatches(d, currentTarget) || currentTarget.tenant !== target.tenant || pointOf(currentOwn) !== point || authorityOf(d, p, currentOwn) !== authority
      || !clientMayRead(d, p) || currentConnection?.origin !== connection.origin || currentConnection.key !== connection.key) return fail("auth.forbidden", "the client network identity changed")
    return result.ok ? { ...result, revision: d.revision() } : result
  } catch { return unavailable() }
}
