import type { Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"
import { resetEventBytes } from "./event-window.ts"

/**
 * Rewrites the params of stored events of `op` with the owner's `redact.params`, for events
 * written before a redaction existed or by a stale build that lacked it. `marker` (in meta)
 * holds the highest event seq already examined, so every call examines only newer events and
 * rewrites only those whose params differ from their redacted form. Unlike a run-once marker,
 * a later call still catches events a stale deploy wrote after an earlier scrub.
 * Returns the number of rewritten events.
 */
export const scrubStoredParams = (sql: SqlStore, t: Tables, redact: ((op: string, params: unknown) => unknown) | undefined, op: string, marker: string): number => {
  if (!redact) return 0
  return sql.transaction(() => {
    const key = `scrub:${marker}`
    const prior = sql.exec<{ value: string }>(`SELECT value FROM ${t.meta} WHERE key = ?`, key)[0]
    const since = prior ? Number(prior.value) || 0 : 0
    const rows = sql.exec<{ seq: number; params: string }>(`SELECT seq, params FROM ${t.events} WHERE op = ? AND seq > ? ORDER BY seq`, op, since)
    let rewritten = 0
    let high = since
    for (const r of rows) {
      high = Math.max(high, r.seq)
      const next = JSON.stringify(redact(op, JSON.parse(r.params)))
      if (next === r.params) continue
      sql.exec(`UPDATE ${t.events} SET params = ? WHERE seq = ?`, next, r.seq)
      rewritten += 1
    }
    // Only a moved mark is written: a bind with nothing new costs no row write.
    if (!prior || high > since) sql.exec(`INSERT OR REPLACE INTO ${t.meta} (key, value) VALUES (?, ?)`, key, String(high))
    // Rewritten params change the stored size: the event byte total is recomputed on its next read.
    if (rewritten > 0) resetEventBytes(sql, t)
    return rewritten
  })
}
