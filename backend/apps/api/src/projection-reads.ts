/**
 * Where projection reads go during the Postgres to Vitess move (plans/cmux-next/vitess-migration-DESIGN.md).
 * PROJECTION_READS: "postgres" (default), "shadow" (answer from Postgres, the same read also runs on
 * MySQL and each request logs a match or a diff with keys only), or "mysql" (after the cutover).
 */
export type ProjectionReadMode = "postgres" | "shadow" | "mysql"

export const projectionReadMode = (env: { readonly PROJECTION_READS?: string }): ProjectionReadMode =>
  env.PROJECTION_READS === "mysql" ? "mysql" : env.PROJECTION_READS === "shadow" ? "shadow" : "postgres"

/** Keys reported per list (an event stays small). */
const KEYS_SHOWN = 20

/**
 * Runs `primary` and `shadow` concurrently and returns the primary's answer (or throws its error).
 * `keys` maps an answer to its ordered row keys (ids, never values); a different set or order is a
 * `projection.read.diff` error event, an equal one a `projection.read.match` event. A shadow failure
 * is logged with its error code only (driver messages can quote values) and never fails the read.
 */
export const shadowRead = async <T>(read: string, primary: () => Promise<T>, shadow: () => Promise<T>, keys: (answer: T) => ReadonlyArray<string>): Promise<T> => {
  const [p, s] = await Promise.allSettled([primary(), shadow()])
  if (p.status === "rejected") throw p.reason
  if (s.status === "rejected") {
    const err = (s.reason as { code?: unknown } | null) ?? {}
    console.error(JSON.stringify({ event: "projection.read.shadow_failed", level: "error", read, code: String(err.code ?? "") }))
    return p.value
  }
  const a = keys(p.value), b = keys(s.value)
  const inB = new Set(b), inA = new Set(a)
  const onlyPrimary = a.filter((k) => !inB.has(k)), onlyShadow = b.filter((k) => !inA.has(k))
  const orderDiffers = onlyPrimary.length === 0 && onlyShadow.length === 0 && a.some((k, i) => b[i] !== k)
  if (onlyPrimary.length + onlyShadow.length > 0 || orderDiffers || a.length !== b.length) {
    console.error(JSON.stringify({ event: "projection.read.diff", level: "error", read, primary_rows: a.length, shadow_rows: b.length, only_primary: onlyPrimary.slice(0, KEYS_SHOWN), only_shadow: onlyShadow.slice(0, KEYS_SHOWN), order_differs: orderDiffers }))
  } else {
    console.log(JSON.stringify({ event: "projection.read.match", read, rows: a.length }))
  }
  return p.value
}
