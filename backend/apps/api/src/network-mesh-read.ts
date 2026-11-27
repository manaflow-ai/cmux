import { NativeMeshId } from "@cmux/protocol"
import { Schema } from "effect"
import type { VmApiConnection } from "./cloud-vm-api-config.ts"
import { networkBody } from "./network-policy-read.ts"
import type { Http } from "./team-domain-external.ts"

export interface NetworkMesh { readonly mesh: string; readonly ipv4_cidr: string }
type MeshRead = { readonly ok: true; readonly value: NetworkMesh } | { readonly ok: false; readonly code: string; readonly message: string; readonly empty?: true }

/** Native meshes allocate aligned /20 blocks in 10.128/9. Never accept a default route. */
export const meshCidr = (value: unknown): value is string => {
  if (typeof value !== "string") return false
  const m = /^10\.(\d{1,3})\.(\d{1,3})\.0\/20$/.exec(value)
  if (!m) return false
  const second = Number(m[1]), third = Number(m[2])
  return second >= 128 && second <= 255 && third <= 240 && third % 16 === 0 && value === `10.${second}.${third}.0/20`
}

export const networkMesh = (body: Record<string, unknown> | null): NetworkMesh | null =>
  body && Schema.is(NativeMeshId)(body.id) && meshCidr(body.ipv4Cidr) ? { mesh: body.id, ipv4_cidr: body.ipv4Cidr } : null

/** Public Native routes, fixed operator configuration, bounded body and no redirect or provider details. */
export const readNetworkMesh = async (http: Http, connection: VmApiConnection, tenant: string, selected?: string): Promise<MeshRead> => {
  const fail = (code: string, message: string): MeshRead => ({ ok: false, code, message })
  const unavailable = () => fail("owner.unreachable", "network target discovery is unavailable")
  if (selected && !Schema.is(NativeMeshId)(selected)) return unavailable()
  try {
    const response = await http(new Request(`${connection.origin}${selected ? `/v1/meshes/${selected}` : "/v1/meshes"}`, {
      method: "GET", redirect: "manual", signal: AbortSignal.timeout(10_000),
      headers: { accept: "application/json", authorization: `Bearer ${connection.key}`, "x-cmux-team-id": tenant }
    }))
    if (response.status !== 200) {
      await response.body?.cancel()
      return response.status === 404 ? fail("selector.not_found", "no available network mesh") : unavailable()
    }
    const body = await networkBody(response), items = selected ? [body] : body?.items
    if (!Array.isArray(items) || items.length > 100) return unavailable()
    if (items.length === 0) return { ok: false, code: "selector.not_found", message: "no available network mesh", empty: true }
    if (items.length !== 1) return fail("validation.invalid", "select a network mesh explicitly")
    const mesh = items[0] as Record<string, unknown> | null
    const value = networkMesh(mesh)
    if (!value || (selected && value.mesh !== selected)) return unavailable()
    return { ok: true, value }
  } catch { return unavailable() }
}
