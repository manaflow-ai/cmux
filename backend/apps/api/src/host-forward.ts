/**
 * Ops and reads HostDO forwarded to the Mac and not yet answered (b1-control-do.md section 3). In
 * SQLite so an evicted object still routes the Mac's answer to the device. An op is keyed by
 * (device, idempotency key) and ends at the Mac's `request-settled`; a read by HostDO's own id,
 * mapped back to the device's read id. Rows past FORWARD_TTL_MS are dropped.
 */

export const FORWARD_TTL_MS = 60_000
export const MAX_FORWARDS_PER_DEVICE = 64

export interface ReadForward {
  readonly device: string
  readonly deviceId: number
}

export class HostForwards {
  constructor(private readonly sql: SqlStorage) {
    sql.exec(`CREATE TABLE IF NOT EXISTS host_fwd_op (device TEXT NOT NULL, key TEXT NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (device, key))`)
    sql.exec(`CREATE TABLE IF NOT EXISTS host_fwd_read (id INTEGER PRIMARY KEY AUTOINCREMENT, device TEXT NOT NULL, device_id INTEGER NOT NULL, at INTEGER NOT NULL)`)
  }

  private count(device: string): number {
    const ops = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM host_fwd_op WHERE device = ?`, device).toArray()[0]?.n ?? 0)
    const reads = Number(this.sql.exec<{ n: number }>(`SELECT COUNT(*) AS n FROM host_fwd_read WHERE device = ?`, device).toArray()[0]?.n ?? 0)
    return ops + reads
  }

  /** Records an op forward; false when the device has too many in flight. A resend of the same key refreshes it. */
  addOp(device: string, key: string, now: number): boolean {
    this.expire(now)
    const known = this.sql.exec(`SELECT 1 FROM host_fwd_op WHERE device = ? AND key = ?`, device, key).toArray().length > 0
    if (!known && this.count(device) >= MAX_FORWARDS_PER_DEVICE) return false
    this.sql.exec(`INSERT INTO host_fwd_op (device, key, at) VALUES (?, ?, ?) ON CONFLICT(device, key) DO UPDATE SET at = excluded.at`, device, key, now)
    return true
  }

  hasOp(device: string, key: string): boolean {
    return this.sql.exec(`SELECT 1 FROM host_fwd_op WHERE device = ? AND key = ?`, device, key).toArray().length > 0
  }

  endOp(device: string, key: string): void {
    this.sql.exec(`DELETE FROM host_fwd_op WHERE device = ? AND key = ?`, device, key)
  }

  /** Records a read forward and returns HostDO's id for it, or null when the device has too many in flight. */
  addRead(device: string, deviceId: number, now: number): number | null {
    this.expire(now)
    if (this.count(device) >= MAX_FORWARDS_PER_DEVICE) return null
    this.sql.exec(`INSERT INTO host_fwd_read (device, device_id, at) VALUES (?, ?, ?)`, device, deviceId, now)
    return Number(this.sql.exec<{ id: number }>(`SELECT last_insert_rowid() AS id`).toArray()[0]!.id)
  }

  /** Takes (and removes) a read forward. */
  takeRead(id: number): ReadForward | undefined {
    const row = this.sql.exec<{ device: string; device_id: number }>(`SELECT device, device_id FROM host_fwd_read WHERE id = ?`, id).toArray()[0]
    if (!row) return undefined
    this.sql.exec(`DELETE FROM host_fwd_read WHERE id = ?`, id)
    return { device: row.device, deviceId: Number(row.device_id) }
  }

  /** Every forward in flight, removed: the Mac went away and their outcome is unknown. */
  drainAll(): { ops: Array<{ device: string; key: string }>; reads: Array<ReadForward> } {
    const ops = this.sql.exec<{ device: string; key: string }>(`SELECT device, key FROM host_fwd_op`).toArray().map((r) => ({ device: r.device, key: r.key }))
    const reads = this.sql.exec<{ device: string; device_id: number }>(`SELECT device, device_id FROM host_fwd_read`).toArray().map((r) => ({ device: r.device, deviceId: Number(r.device_id) }))
    this.sql.exec(`DELETE FROM host_fwd_op`)
    this.sql.exec(`DELETE FROM host_fwd_read`)
    return { ops, reads }
  }

  /** Removes forwards past the TTL and returns them (their outcome is unknown to the device). */
  expire(now: number): { ops: Array<{ device: string; key: string }>; reads: Array<ReadForward> } {
    const cut = now - FORWARD_TTL_MS
    const ops = this.sql.exec<{ device: string; key: string }>(`SELECT device, key FROM host_fwd_op WHERE at < ?`, cut).toArray().map((r) => ({ device: r.device, key: r.key }))
    const reads = this.sql.exec<{ device: string; device_id: number }>(`SELECT device, device_id FROM host_fwd_read WHERE at < ?`, cut).toArray().map((r) => ({ device: r.device, deviceId: Number(r.device_id) }))
    this.sql.exec(`DELETE FROM host_fwd_op WHERE at < ?`, cut)
    this.sql.exec(`DELETE FROM host_fwd_read WHERE at < ?`, cut)
    return { ops, reads }
  }

  /** When the oldest forward expires, or null. */
  nextExpiry(): number | null {
    const a = this.sql.exec<{ at: number | null }>(`SELECT MIN(at) AS at FROM (SELECT at FROM host_fwd_op UNION ALL SELECT at FROM host_fwd_read)`).toArray()[0]?.at
    return a === null || a === undefined ? null : Number(a) + FORWARD_TTL_MS
  }
}
