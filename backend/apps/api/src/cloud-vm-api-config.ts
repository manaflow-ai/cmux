import type { Env } from "./env.ts"

export type CloudTransport = "direct" | "vm-api"
export interface VmApiSettings {
  readonly origin: string
  readonly key: string
  readonly image: { readonly id: string; readonly revision: string }
}

/** Operator configuration only; callers never choose an endpoint, credential or image revision. */
export const vmApiSettings = (env: Env): VmApiSettings | null => {
  const { CLOUD_VM_API_ORIGIN: origin, CLOUD_VM_API_SERVICE_KEY: key, CLOUD_VM_API_IMAGE: id, CLOUD_VM_API_IMAGE_REVISION: revision } = env
  if (!origin || !key || !id || !revision || /[\r\n]/.test(key) || key !== key.trim()) return null
  if (!/^[a-z][a-z0-9-]{0,62}$/.test(id) || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(revision)) return null
  try {
    const u = new URL(origin)
    if (u.protocol !== "https:" || u.origin !== origin || u.username || u.password || u.search || u.hash) return null
    return { origin, key, image: { id, revision } }
  } catch { return null }
}

/** Missing markers belong to the legacy driver. Unknown persisted values never fall back. */
export const transportOf = (row: { readonly transport?: CloudTransport }): CloudTransport | null =>
  row.transport === undefined || row.transport === "direct" ? "direct" : row.transport === "vm-api" ? "vm-api" : null
