import type { Principal } from "@cmux/ownership"
import { HostNetworkTarget, NativeMeshId } from "@cmux/protocol"
import { Schema } from "effect"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { admit, decodeParams } from "./domains/common.ts"
import { can } from "./domains/team-members.ts"
import { installPublicPoint } from "./install-public-point.ts"
import { networkBody, type NetworkIdentityDeps } from "./network-policy-read.ts"
import type { ReadResult } from "./owner-do.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

type Deps = Omit<NetworkIdentityDeps, "origin" | "stream" | "submitSystem"> & {
  readonly connection: () => VmApiConnection | null
  readonly revision: () => string
}
const pointOf = (key: JsonWebKey | null): string | null => { try { return key ? installPublicPoint(key) : null } catch { return null } }
const tenantMatches = (d: Deps, t: VmApiTenant | null): t is VmApiTenant => t?.team === d.team && t.project === d.project
const clientMayRead = (d: Deps, p: Principal): boolean => {
  const state = d.state()
  return p.kind === "install" && !p.agent && ["mac", "ios", "cli"].includes(p.install_kind ?? "") && p.team === d.team
    && !!p.user && !!p.install && !!p.grant && state.team?.id === d.team && state.team.deleted_at === undefined
    && !state.server_revocations?.[p.install] && can(state, d.rows, p.user, "team.resources")
}

/** Current Native meshes are /20 blocks in 10.128/9. Never hand an app a default route. */
const meshCidr = (value: unknown): value is string => {
  if (typeof value !== "string") return false
  const match = /^10\.(\d{1,3})\.(\d{1,3})\.0\/20$/.exec(value)
  if (!match) return false
  const second = Number(match[1]), third = Number(match[2])
  return second >= 128 && second <= 255 && third <= 240 && third % 16 === 0 && value === `10.${second}.${third}.0/20`
}

/** Read-only routing discovery. Native ownership and current owner authorization must both agree. */
export const hostNetworkTarget = async (d: Deps, p: Principal, params: unknown): Promise<ReadResult> => {
  const fail = (code: string, message: string): ReadResult => ({ ok: false, code, message })
  const unavailable = () => fail("owner.unreachable", "network target discovery is unavailable")
  const admission = admit("cloud:TeamDO", HostNetworkTarget.name, p, () => p.grant_classes ? { op_classes: p.grant_classes, revoked_at: null, expires_at: null } : undefined, d.now())
  if (admission) return { ...admission, ok: false }
  const decoded = decodeParams<typeof HostNetworkTarget.params.Type>(HostNetworkTarget, params)
  if (!decoded.ok) return fail("validation.invalid", "invalid network target selector")
  if (!clientMayRead(d, p)) return fail("auth.forbidden", "only an active client may discover its team network")
  const connection = d.connection()
  if (!connection) return unavailable()
  try {
    const [target, key] = await Promise.all([d.tenant(), d.key(p.user!, p.install!, p.grant!)])
    const point = pointOf(key)
    if (!tenantMatches(d, target) || !point) return fail("auth.forbidden", "the client network owner could not be verified")
    const selected = decoded.value.mesh
    const path = selected ? `/v1/meshes/${selected}` : "/v1/meshes"
    const response = await d.http(new Request(`${connection.origin}${path}`, {
      method: "GET", redirect: "manual", signal: AbortSignal.timeout(10_000),
      headers: { accept: "application/json", authorization: `Bearer ${connection.key}`, "x-cmux-team-id": target.tenant }
    }))
    let result: ReadResult
    if (response.status === 404) { await response.body?.cancel(); result = fail("selector.not_found", "no available network mesh") }
    else if (response.status !== 200) { await response.body?.cancel(); result = unavailable() }
    else {
      const body = await networkBody(response)
      const items = selected ? [body] : body?.items
      if (!Array.isArray(items) || items.length > 100) result = unavailable()
      else if (items.length === 0) result = fail("selector.not_found", "no available network mesh")
      else if (items.length !== 1) result = fail("validation.invalid", "select a network mesh explicitly")
      else {
        const mesh = items[0] as Record<string, unknown> | null
        if (!mesh || !Schema.is(NativeMeshId)(mesh.id) || (selected && mesh.id !== selected) || !meshCidr(mesh.ipv4Cidr)) result = unavailable()
        else result = { ok: true, value: { team: d.team, tenant: target.tenant, project: target.project, origin: connection.origin, mesh: mesh.id, ipv4_cidr: mesh.ipv4Cidr }, revision: "" }
      }
    }
    const currentTarget = await d.tenant()
    const currentKey = await d.key(p.user!, p.install!, p.grant!)
    const currentConnection = d.connection()
    // No await between final live membership/key/config checks and returning metadata.
    if (!tenantMatches(d, currentTarget) || currentTarget.tenant !== target.tenant || pointOf(currentKey) !== point || !clientMayRead(d, p)
      || currentConnection?.origin !== connection.origin || currentConnection.key !== connection.key) return fail("auth.forbidden", "the client network identity changed")
    return result.ok ? { ...result, revision: d.revision() } : result
  } catch { return unavailable() }
}
