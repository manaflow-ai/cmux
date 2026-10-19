import { createCmuxVmClient, type components } from "@cmux/vm"
import type { Env } from "./env.ts"
import type { PairingRecord } from "./pairing-do.ts"
import type { VmApiTenant } from "./team-vm-api-tenant.ts"

/** Public approval intent; pinned before the first external effect. */
export interface PairingApproval { readonly team: string; readonly name: string; readonly mesh: string | null }
/** Short-lived and private to PairingDO and its collect socket. Never an owner event or op result. */
export type ServerNetworkEnrollment = components["schemas"]["OverlayServerCode"] & { readonly origin: string }
/** Request-scoped, authenticated human session; never taken from op params or persisted. */
export interface PairNetworkTransport { readonly session?: string; readonly fetch?: typeof fetch }

export const nativeMesh = (value: unknown): value is string => typeof value === "string" && /^mesh_[0-9a-hjkmnp-tv-z]{26}$/.test(value)
export const nativeServerName = (value: string): boolean => /^[A-Za-z0-9][A-Za-z0-9._ -]{0,62}$/.test(value)
const tenantId = (value: unknown): value is string => typeof value === "string" && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(value)
const originOf = (value: unknown): string | null => {
  if (typeof value !== "string") return null
  try { const url = new URL(value); return url.protocol === "https:" && url.origin === value && !url.username && !url.password ? value : null } catch { return null }
}
const publicPoint = (record: PairingRecord): string => {
  const decode = (v: string) => Uint8Array.from(atob(v.replace(/-/g, "+").replace(/_/g, "/").padEnd(44, "=")), (c) => c.charCodeAt(0))
  const x = decode(record.public_jwk.x), y = decode(record.public_jwk.y)
  if (x.length !== 32 || y.length !== 32) throw new Error("invalid install point")
  return btoa(String.fromCharCode(4, ...x, ...y))
}

export const sameApproval = (a: PairingApproval, b: PairingApproval) => a.team === b.team && a.name === b.name && a.mesh === b.mesh
export const networkLocator = (grant: ServerNetworkEnrollment) => ({ state: "reserved" as const, tenant: grant.tenantId, mesh: grant.meshId, device: grant.deviceId })

/** PairingDO revalidates the key/name binding before storing or releasing a secret. */
export const networkMatchesPairing = (grant: ServerNetworkEnrollment, record: PairingRecord, approval: PairingApproval, now: number): boolean => {
  try {
    const expiry = Date.parse(grant.expiresAt)
    return originOf(grant.origin) !== null && /^msc_[0-9a-hjkmnp-tv-z]{26}$/.test(grant.code) && /^dev_[0-9a-hjkmnp-tv-z]{26}$/.test(grant.deviceId)
      && tenantId(grant.tenantId) && nativeMesh(grant.meshId) && grant.meshId === approval.mesh
      && grant.binding.name === approval.name && grant.binding.wgPublicKey === record.wg_public_key && grant.binding.installPublicKey === publicPoint(record)
      && expiry > now && expiry >= record.expires_at && expiry <= now + 720_000
  } catch { return false }
}

type Failure = { readonly ok: false; readonly code: string; readonly message: string; readonly retryable: boolean }
const unavailable = (message = "Server network enrollment is unavailable", retryable = true): Failure => ({ ok: false, code: "owner.unreachable", message, retryable })

/** Uses only the approving human's session and authoritative owner routing, never a mesh service grant. */
export const issuePairNetwork = async (env: Env, approval: PairingApproval, record: PairingRecord, transport: PairNetworkTransport): Promise<{ ok: true; grant: ServerNetworkEnrollment } | Failure> => {
  const origin = originOf(env.CLOUD_VM_API_ORIGIN)
  if (!origin || !transport.session || /[\r\n]/.test(transport.session) || !nativeMesh(approval.mesh) || !nativeServerName(approval.name)) return unavailable(undefined, false)
  try {
    const owner = env.TEAM_DO.get(env.TEAM_DO.idFromName(approval.team))
    let target: VmApiTenant | null = await owner.vmApiTenant(approval.team, "operate")
    if (!target) {
      const ensured = await owner.ensureVmApiTenant(approval.team)
      if (ensured.status !== "ready") return unavailable()
      target = await owner.vmApiTenant(approval.team, "operate")
    }
    if (!target || target.team !== approval.team || target.project !== env.STACK_PROJECT_ID || !tenantId(target.tenant)) return unavailable("The team's network identity could not be verified", false)
    const binding = { name: approval.name, wgPublicKey: record.wg_public_key, installPublicKey: publicPoint(record) }
    const client = createCmuxVmClient({ token: transport.session, teamId: target.tenant, baseUrl: origin, fetch: (request) => (transport.fetch ?? fetch)(new Request(request, { redirect: "manual", signal: AbortSignal.timeout(15_000) })) })
    const { data, response } = await client.POST("/v1/meshes/{meshId}/overlay-server-codes", { params: { path: { meshId: approval.mesh } }, body: binding })
    if (response.status !== 201 || !data) {
      if (response.status === 401 || response.status === 403) return { ok: false, code: "auth.forbidden", message: "The signed-in user cannot approve this network enrollment", retryable: false }
      if (response.status === 404) return { ok: false, code: "selector.not_found", message: "The selected network is unavailable for this team", retryable: false }
      if (response.status === 400 || response.status === 409) return { ok: false, code: "validation.invalid", message: "The server's public network identity could not be enrolled", retryable: false }
      return unavailable()
    }
    // Copy only the contract fields, never arbitrary response fields into durable state or the socket.
    const grant: ServerNetworkEnrollment = { origin, code: data.code, deviceId: data.deviceId, meshId: data.meshId, tenantId: data.tenantId, expiresAt: data.expiresAt, binding: { name: data.binding.name, wgPublicKey: data.binding.wgPublicKey, installPublicKey: data.binding.installPublicKey } }
    if (grant.tenantId !== target.tenant || !networkMatchesPairing(grant, record, approval, Date.now())) return unavailable("Server network approval could not be verified", false)
    return { ok: true, grant }
  } catch { return unavailable() }
}
