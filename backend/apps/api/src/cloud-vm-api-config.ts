import type { Env } from "./env.ts"

export type CloudTransport = "direct" | "vm-api"
export interface VmApiConnection {
  readonly origin: string
  readonly key: string
}
export interface VmApiSettings extends VmApiConnection {
  readonly image: { readonly id: string; readonly revision: string }
}

/** The configured VM API origin, valid only as a bare https origin. Needs no service key. */
export const vmApiOrigin = (env: Pick<Env, "CLOUD_VM_API_ORIGIN">): string | null => {
  const origin = env.CLOUD_VM_API_ORIGIN
  if (!origin) return null
  try {
    const u = new URL(origin)
    if (u.protocol !== "https:" || u.origin !== origin || u.username || u.password || u.search || u.hash) return null
    return origin
  } catch { return null }
}

/** Operator configuration only; callers never choose an endpoint, credential or image revision. */
export const vmApiConnection = (env: Env): VmApiConnection | null => {
  const origin = vmApiOrigin(env), key = env.CLOUD_VM_API_SERVICE_KEY
  if (!origin || !key || /[\r\n]/.test(key) || key !== key.trim()) return null
  return { origin, key }
}

export const vmApiSettings = (env: Env): VmApiSettings | null => {
  const connection = vmApiConnection(env)
  const { CLOUD_VM_API_IMAGE: id, CLOUD_VM_API_IMAGE_REVISION: revision } = env
  if (!connection || !id || !revision || !/^[a-z][a-z0-9-]{0,62}$/.test(id) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(revision)) return null
  return { ...connection, image: { id, revision } }
}

/** Missing markers belong to the legacy driver. Unknown persisted values never fall back. */
export const transportOf = (row: { readonly transport?: CloudTransport }): CloudTransport | null =>
  row.transport === undefined || row.transport === "direct" ? "direct" : row.transport === "vm-api" ? "vm-api" : null
