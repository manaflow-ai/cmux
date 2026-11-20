import type { Env } from "../env.ts"
import type { Kill, ModelCatalogDO, StoredVersion } from "./catalog-do.ts"

/**
 * Reads of the live model catalog's store (catalog-do.ts) shared by the catalog routes and the model
 * router's kill check. One isolate reuses what it read for ISOLATE_TTL_MS, so a kill reaches every
 * isolate within that time and the hot path asks the object at most twice a minute.
 */

export const ROUTER_HARNESS = "cmux"
const ISOLATE_TTL_MS = 30_000

export const catalogStub = (env: Env): DurableObjectStub<ModelCatalogDO> => env.MODEL_CATALOG_DO!.get(env.MODEL_CATALOG_DO!.idFromName("global"))

let snapshot: { at: number; stored: StoredVersion | null; kills: ReadonlyArray<Kill> } | undefined

/** The stored version and kills; `fresh` skips this isolate's copy. */
export const readCatalog = async (env: Env, fresh = false) => {
  if (!fresh && snapshot && Date.now() - snapshot.at < ISOLATE_TTL_MS) return snapshot
  const s = catalogStub(env)
  const [stored, kills] = await Promise.all([s.current(), s.kills()])
  snapshot = { at: Date.now(), stored, kills }
  return snapshot
}

/** Test hook. */
export const resetCatalogSnapshot = () => {
  snapshot = undefined
}

/** Router model ids a kill names (for the `cmux` harness or every harness): the router refuses them. */
export const killedRouterModels = async (env: Env): Promise<ReadonlySet<string>> => {
  if (!env.MODEL_CATALOG_DO) return new Set()
  try {
    const { kills } = await readCatalog(env)
    return new Set(kills.filter((k) => k.harness === "*" || k.harness === ROUTER_HARNESS).map((k) => k.model))
  } catch {
    // The catalog store is unreachable: keep serving (a kill is a soft brake; the daily caps are the hard one).
    return new Set()
  }
}
