import type { Tables } from "./schema.ts"
import type { SqlStore } from "./sql.ts"
import type { RejectFrame, ResultFrame } from "./types.ts"

/**
 * What the request ledger keeps of a successful reply, for owners whose replies carry text that
 * must not outlive the entity (FeedDO: a feed.post reply holds the whole item, and the ledger
 * keeps decided keys for 7 days, longer than an evicted item). `store` reduces the value before
 * it is written; `replay` rebuilds the answer to a retried key from the current state (or
 * refuses when the entity is gone).
 */
export interface LedgerReplyRedaction {
  readonly store: (op: string, value: unknown) => unknown
  readonly replay: (op: string, stored: unknown, state: unknown) => { ok: true; value: unknown } | { ok: false; code: string; message: string }
}

/** The JSON the ledger stores for `out`. */
export const ledgerReplyText = (redaction: LedgerReplyRedaction | undefined, op: string, out: ResultFrame | RejectFrame): string =>
  JSON.stringify(redaction && out.t === "result" ? { ...out, value: redaction.store(op, out.value) } : out)

/** The answer to a retried decided key. */
export const replayedReply = (redaction: LedgerReplyRedaction | undefined, op: string, stored: ResultFrame | RejectFrame, state: unknown): ResultFrame | RejectFrame => {
  if (!redaction || stored.t !== "result") return { ...stored, replayed: true }
  const r = redaction.replay(op, stored.value, state)
  if (r.ok) return { ...stored, value: r.value, replayed: true }
  return { t: "reject", tx: stored.tx, idempotency_key: stored.idempotency_key, code: r.code, message: r.message, retryable: false, replayed: true }
}

/**
 * Rewrites stored ledger replies of `op` with `redaction.store`, for rows written before the
 * redaction existed or by a stale build. `marker` (in meta) holds the newest examined
 * `created_at`, so each call examines only newer rows and rewrites only replies that change.
 */
export const scrubStoredReplies = (sql: SqlStore, t: Tables, redaction: LedgerReplyRedaction | undefined, op: string, marker: string): number => {
  if (!redaction) return 0
  return sql.transaction(() => {
    const key = `scrub:${marker}`
    const prior = sql.exec<{ value: string }>(`SELECT value FROM ${t.meta} WHERE key = ?`, key)[0]
    const since = prior ? Number(prior.value) || 0 : -1
    const rows = sql.exec<{ identity: string; idempotency_key: string; reply: string; created_at: number }>(
      `SELECT identity, idempotency_key, reply, created_at FROM ${t.ledger} WHERE op = ? AND ok = 1 AND created_at >= ? ORDER BY created_at`,
      op,
      since
    )
    let rewritten = 0
    let high = since
    for (const r of rows) {
      high = Math.max(high, Number(r.created_at))
      const next = ledgerReplyText(redaction, op, JSON.parse(r.reply) as ResultFrame)
      if (next === r.reply) continue
      sql.exec(`UPDATE ${t.ledger} SET reply = ? WHERE identity = ? AND idempotency_key = ?`, next, r.identity, r.idempotency_key)
      rewritten += 1
    }
    if (!prior || high > since) sql.exec(`INSERT OR REPLACE INTO ${t.meta} (key, value) VALUES (?, ?)`, key, String(high))
    return rewritten
  })
}
