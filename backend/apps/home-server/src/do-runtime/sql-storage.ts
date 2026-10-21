import type { Database, SQLQueryBindings } from "bun:sqlite"

/** A value SQLite binds (Durable Object SQL binds the same set; blobs come back as ArrayBuffer). */
type Bindable = string | number | bigint | boolean | null | Uint8Array | ArrayBuffer

/** First keyword of a statement batch that may hold several statements and returns no rows. */
const BATCH_KEYWORDS = /^\s*(create|drop|alter|insert|update|delete|pragma|begin|commit|replace)\b/i

/** A Durable Object SQL cursor: the rows of one `exec`, read once. */
export interface SqlCursor<T> extends Iterable<T> {
  toArray(): Array<T>
  one(): T
  raw(): IterableIterator<Array<unknown>>
  readonly columnNames: Array<string>
  readonly rowsRead: number
  readonly rowsWritten: number
}

const toBinding = (v: unknown): Bindable => {
  if (v === undefined) return null
  if (v instanceof ArrayBuffer) return new Uint8Array(v)
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength)
  return v as Bindable
}

/** Blobs come back as ArrayBuffer, as in Durable Object SQL. */
const fromColumn = (v: unknown): unknown => (v instanceof Uint8Array ? v.buffer.slice(v.byteOffset, v.byteOffset + v.byteLength) : v)

const cursorOf = <T>(rows: Array<T>, columnNames: Array<string>, written: number): SqlCursor<T> => ({
  toArray: () => rows,
  one: () => {
    if (rows.length !== 1) throw new Error(`Expected exactly one result from SQL query, but got ${rows.length === 0 ? "no results" : "multiple results"}.`)
    return rows[0]!
  },
  raw: () => rows.map((r) => columnNames.map((c) => (r as Record<string, unknown>)[c]))[Symbol.iterator](),
  columnNames,
  rowsRead: rows.length,
  rowsWritten: written,
  [Symbol.iterator]: () => rows[Symbol.iterator]()
})

/**
 * `ctx.storage.sql` over one `bun:sqlite` database: `exec(query, ...bindings)` returns a cursor of
 * row objects, like Durable Object SQL. A batch of several statements with no bindings runs them all.
 */
export class SqlStorage {
  constructor(private readonly db: Database) {}

  exec<T = Record<string, unknown>>(query: string, ...bindings: Array<unknown>): SqlCursor<T> {
    if (bindings.length === 0 && BATCH_KEYWORDS.test(query) && /;\s*\S/.test(query.trim().replace(/;$/, ""))) {
      const before = this.totalChanges()
      this.db.run(query)
      return cursorOf<T>([], [], this.totalChanges() - before)
    }
    const stmt = this.db.prepare(query)
    try {
      const params = bindings.map(toBinding) as Array<SQLQueryBindings>
      if (stmt.columnNames.length === 0) {
        const r = stmt.run(...params)
        return cursorOf<T>([], [], r.changes)
      }
      const before = this.totalChanges()
      const rows = (stmt.all(...params) as Array<Record<string, unknown>>).map((row) => {
        for (const k of Object.keys(row)) row[k] = fromColumn(row[k])
        return row as T
      })
      return cursorOf<T>(rows, stmt.columnNames, this.totalChanges() - before)
    } finally {
      stmt.finalize()
    }
  }

  /** The database size in bytes (Durable Object `sql.databaseSize`). */
  get databaseSize(): number {
    const r = this.db.query("SELECT page_count * page_size AS n FROM pragma_page_count(), pragma_page_size()").get() as { n: number } | null
    return r?.n ?? 0
  }

  private totalChanges(): number {
    return (this.db.query("SELECT total_changes() AS n").get() as { n: number }).n
  }
}
