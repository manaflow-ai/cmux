import type { Env } from "./env.ts"

export type CloudTransport = "direct" | "vm-api"
export interface VmApiConnection {
  readonly origin: string
  readonly key: string
}
export interface VmApiSettings extends VmApiConnection {
  readonly image: { readonly id: string; readonly revision: string }
}

/** Operator configuration only; callers never choose an endpoint, credential or image revision. */
export const vmApiConnection = (env: Env): VmApiConnection | null => {
  const { CLOUD_VM_API_ORIGIN: origin, CLOUD_VM_API_SERVICE_KEY: key } = env
  if (!origin || !key || /[\r\n]/.test(key) || key !== key.trim()) return null
  try {
    const u = new URL(origin)
    if (u.protocol !== "https:" || u.origin !== origin || u.username || u.password || u.search || u.hash) return null
    return { origin, key }
  } catch { return null }
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
