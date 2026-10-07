import { conversation } from "@cmux/home-core"

/**
 * Home attachment quota (home-scale.md B9 owner counters), in the UserDO's SQLite: per rolling
 * 24 h, 300 intents and 2 GB of declared bytes, and 10 GB stored (objects this user uploaded first
 * that still exist). `key` is the upload slot: every slot is charged; the ConversationDO refunds a
 * slot whose commit finds the bytes already stored or that expires without a commit.
 */
type Sql = SqlStorage
export type TakeResult = conversation.QuotaResult | { ok: false; code: "auth.forbidden"; window: "none"; retry_after_ms: 0 }
export const FORBIDDEN: TakeResult = { ok: false, code: "auth.forbidden", window: "none", retry_after_ms: 0 }

export const ensureTables = (sql: Sql): void => {
  sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_usage (key TEXT PRIMARY KEY, bytes INTEGER NOT NULL, at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_intents (at INTEGER NOT NULL)`)
  sql.exec(`CREATE TABLE IF NOT EXISTS home_attachment_stored (object_key TEXT PRIMARY KEY, bytes INTEGER NOT NULL)`)
}

const storedBytes = (sql: Sql): number => Number(sql.exec<{ b: number }>(`SELECT COALESCE(SUM(bytes), 0) AS b FROM home_attachment_stored`).toArray()[0]?.b ?? 0)

export const take = (sql: Sql, key: string, bytes: number, now: number): TakeResult => {
  const since = now - conversation.ATTACHMENT_LIMITS.quota.dayMs
  sql.exec(`DELETE FROM home_attachment_usage WHERE at <= ?`, since)
  sql.exec(`DELETE FROM home_attachment_intents WHERE at <= ?`, since)
  // The same slot key again (a retried RPC) is already charged.
  if (sql.exec(`SELECT 1 FROM home_attachment_usage WHERE key = ?`, key).toArray().length > 0) return { ok: true }
  const usage = {
    bytes: sql.exec<{ bytes: number; at: number }>(`SELECT bytes, at FROM home_attachment_usage`).toArray().map((r) => ({ bytes: Number(r.bytes), at: Number(r.at) })),
    intents: sql.exec<{ at: number }>(`SELECT at FROM home_attachment_intents`).toArray().map((r) => Number(r.at)),
    stored: storedBytes(sql)
  }
  const decision = conversation.attachmentQuota(usage, bytes, now)
  if (decision.ok) {
    sql.exec(`INSERT INTO home_attachment_intents (at) VALUES (?)`, now)
    sql.exec(`INSERT INTO home_attachment_usage (key, bytes, at) VALUES (?, ?, ?)`, key, bytes, now)
  }
  return decision
}

/** Gives back a slot's declared bytes (its commit found the bytes already stored, or it expired unused). The intent still counts. */
export const refund = (sql: Sql, key: string): void => void sql.exec(`DELETE FROM home_attachment_usage WHERE key = ?`, key)

/** An object this user uploaded first now exists (counts toward the 10 GB stored cap). Idempotent by key. */
export const recordStored = (sql: Sql, objectKey: string, bytes: number): void =>
  void sql.exec(`INSERT INTO home_attachment_stored (object_key, bytes) VALUES (?, ?) ON CONFLICT (object_key) DO NOTHING`, objectKey, bytes)

/** The object was collected or its conversation deleted. Idempotent by key. */
export const releaseStored = (sql: Sql, objectKey: string): void => void sql.exec(`DELETE FROM home_attachment_stored WHERE object_key = ?`, objectKey)
