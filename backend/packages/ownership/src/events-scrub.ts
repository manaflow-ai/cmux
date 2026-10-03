import type { Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"

/**
 * Rewrites the params of stored events of `op` with the owner's `redact.params`, for logs
 * written before a redaction existed. Runs once per `marker` (recorded in meta); returns the
 * number of rewritten events.
 */
export const scrubStoredParams = (sql: SqlStore, t: Tables, redact: ((op: string, params: unknown) => unknown) | undefined, op: string, marker: string): number => {
  if (!redact) return 0
  return sql.transaction(() => {
    const key = `scrub:${marker}`
    if (sql.exec(`SELECT 1 FROM ${t.meta} WHERE key = ?`, key).length > 0) return 0
    const rows = sql.exec<{ seq: number; params: string }>(`SELECT seq, params FROM ${t.events} WHERE op = ?`, op)
    for (const r of rows) sql.exec(`UPDATE ${t.events} SET params = ? WHERE seq = ?`, JSON.stringify(redact(op, JSON.parse(r.params))), r.seq)
    sql.exec(`INSERT INTO ${t.meta} (key, value) VALUES (?, ?)`, key, String(rows.length))
    return rows.length
  })
}
