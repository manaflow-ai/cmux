import { Database } from "bun:sqlite"
import { deserialize, serialize } from "bun:jsc"
import { SqlStorage } from "./sql-storage.ts"

/** Called when an object's alarm time changes (null: no alarm), so the runtime can arm its timer. */
export type AlarmListener = (at: number | null) => void

/**
 * `ctx.storage` of one object: its own SQLite file (WAL, synchronous FULL), SQL, synchronous
 * transactions, the key-value API and the alarm. Writes are durable when the call returns, so
 * there is no output gate to model: a reply is sent only after its commit.
 */
export class ObjectStorage {
  readonly sql: SqlStorage
  private readonly db: Database
  private alarmListener: AlarmListener = () => {}

  constructor(path: string) {
    this.db = new Database(path, { create: true, strict: false })
    this.db.run("PRAGMA journal_mode = WAL")
    this.db.run("PRAGMA synchronous = FULL")
    this.db.run("PRAGMA foreign_keys = OFF")
    this.db.run("CREATE TABLE IF NOT EXISTS _cf_kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    this.db.run("CREATE TABLE IF NOT EXISTS _cf_alarm (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL)")
    this.sql = new SqlStorage(this.db)
  }

  /** The runtime's hook for alarm changes (one listener per object). */
  onAlarmChange(listener: AlarmListener): void {
    this.alarmListener = listener
  }

  /** Runs `fn` in one transaction (a savepoint when nested); a throw rolls back every write. */
  transactionSync<T>(fn: () => T): T {
    return this.db.transaction(fn)()
  }

  /** Async transaction (Durable Object `storage.transaction`): the callback gets this storage. */
  async transaction<T>(fn: (txn: ObjectStorage) => Promise<T> | T): Promise<T> {
    this.db.run("SAVEPOINT do_txn")
    try {
      const r = await fn(this)
      this.db.run("RELEASE do_txn")
      return r
    } catch (e) {
      this.db.run("ROLLBACK TO do_txn")
      this.db.run("RELEASE do_txn")
      throw e
    }
  }

  async get<T = unknown>(key: string | Array<string>): Promise<T | Map<string, unknown> | undefined> {
    if (Array.isArray(key)) {
      const out = new Map<string, unknown>()
      for (const k of key) {
        const v = await this.get(k)
        if (v !== undefined) out.set(k, v)
      }
      return out
    }
    const row = this.db.query("SELECT value FROM _cf_kv WHERE key = ?").get(key) as { value: Uint8Array } | null
    return row ? (deserialize(row.value) as T) : undefined
  }

  async put(key: string | Record<string, unknown>, value?: unknown): Promise<void> {
    if (typeof key === "object") {
      this.transactionSync(() => {
        for (const [k, v] of Object.entries(key)) this.putOne(k, v)
      })
      return
    }
    this.putOne(key, value)
  }

  private putOne(key: string, value: unknown): void {
    this.db.prepare("INSERT INTO _cf_kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, new Uint8Array(serialize(value)))
  }

  async delete(key: string | Array<string>): Promise<boolean | number> {
    if (Array.isArray(key)) {
      let n = 0
      for (const k of key) if (await this.delete(k)) n++
      return n
    }
    return this.db.prepare("DELETE FROM _cf_kv WHERE key = ?").run(key).changes > 0
  }

  async list<T = unknown>(options: { prefix?: string; start?: string; end?: string; limit?: number; reverse?: boolean } = {}): Promise<Map<string, T>> {
    const where: Array<string> = []
    const params: Array<string | number> = []
    if (options.prefix !== undefined) [where.push("key >= ? AND key < ?"), params.push(options.prefix, `${options.prefix}￿`)]
    if (options.start !== undefined) [where.push("key >= ?"), params.push(options.start)]
    if (options.end !== undefined) [where.push("key < ?"), params.push(options.end)]
    const sql = `SELECT key, value FROM _cf_kv ${where.length ? `WHERE ${where.join(" AND ")}` : ""} ORDER BY key ${options.reverse ? "DESC" : "ASC"}${options.limit ? ` LIMIT ${Math.floor(options.limit)}` : ""}`
    const rows = this.db.query(sql).all(...params) as Array<{ key: string; value: Uint8Array }>
    return new Map(rows.map((r) => [r.key, deserialize(r.value) as T]))
  }

  async deleteAll(): Promise<void> {
    const tables = this.db.query("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").all() as Array<{ name: string }>
    this.transactionSync(() => {
      for (const t of tables) this.db.run(`DROP TABLE IF EXISTS "${t.name.replace(/"/g, '""')}"`)
    })
    this.db.run("CREATE TABLE IF NOT EXISTS _cf_kv (key TEXT PRIMARY KEY, value BLOB NOT NULL)")
    this.db.run("CREATE TABLE IF NOT EXISTS _cf_alarm (id INTEGER PRIMARY KEY CHECK (id = 1), at INTEGER NOT NULL)")
    this.alarmListener(null)
  }

  /** The stored alarm time, synchronously (the runtime re-arms timers at start). */
  alarmAt(): number | null {
    const row = this.db.query("SELECT at FROM _cf_alarm WHERE id = 1").get() as { at: number } | null
    return row ? Number(row.at) : null
  }

  async getAlarm(): Promise<number | null> {
    return this.alarmAt()
  }

  async setAlarm(at: number | Date): Promise<void> {
    const t = typeof at === "number" ? at : at.getTime()
    if (!Number.isFinite(t) || t <= 0) throw new TypeError("setAlarm needs a positive time")
    this.db.prepare("INSERT INTO _cf_alarm (id, at) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET at = excluded.at").run(Math.floor(t))
    this.alarmListener(Math.floor(t))
  }

  async deleteAlarm(): Promise<void> {
    this.db.run("DELETE FROM _cf_alarm WHERE id = 1")
    this.alarmListener(null)
  }

  /** Closes the database file (runtime shutdown). */
  close(): void {
    this.db.close()
  }
}
