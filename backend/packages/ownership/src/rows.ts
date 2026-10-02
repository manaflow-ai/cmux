import type { SqlStore } from "./sql.ts"

/**
 * Row-backed domains (lane 15 need E1): a domain whose state cannot live in one
 * JSON value (a conversation with a million messages) keeps a small head in the
 * state and the rest in named row tables. The reducer reads rows only through a
 * RowReader and returns RowWrites, which the engine commits in the same
 * transaction as the ledger, events and outbox.
 */
export interface StoredRow<T = unknown> {
  readonly key: string
  /** Order within the table (for example the message seq); null when unordered. */
  readonly n: number | null
  readonly row: T
}

export interface RowRange {
  /** Exclusive lower bound on `n`. */
  readonly after?: number
  /** Exclusive upper bound on `n`. */
  readonly before?: number
  readonly limit: number
  readonly desc?: boolean
}

export interface RowReader {
  get<T>(table: string, key: string): StoredRow<T> | undefined
  range<T>(table: string, range: RowRange): Array<StoredRow<T>>
}

export type RowWrite =
  | { readonly table: string; readonly op: "upsert"; readonly key: string; readonly n?: number | null; readonly row: unknown }
  | { readonly table: string; readonly op: "delete"; readonly key: string }

const TABLE = /^[a-z][a-z0-9_]{0,62}$/

export const checkWrites = (writes: ReadonlyArray<RowWrite>): void => {
  for (const w of writes) {
    if (!TABLE.test(w.table)) throw new Error(`invalid row table ${w.table}`)
    if (typeof w.key !== "string" || w.key.length === 0 || w.key.length > 256) throw new Error(`invalid row key in ${w.table}`)
  }
}

/** A RowReader that hides the writer methods of the object behind it (reducers only read). */
export const readOnly = (r: RowReader): RowReader => ({ get: (t, k) => r.get(t, k), range: (t, q) => r.range(t, q) })

/** The reader JSON-only domains get: no rows exist for them. */
export const EMPTY_ROWS: RowReader = { get: () => undefined, range: () => [] }

/** Rows in the engine's SQLite table. `n` is unique per table (range cursors rely on it). */
export class SqlRows implements RowReader {
  constructor(
    private readonly sql: SqlStore,
    private readonly table: string
  ) {}

  get<T>(tbl: string, key: string): StoredRow<T> | undefined {
    const r = this.sql.exec<{ k: string; n: number | null; json: string }>(`SELECT k, n, json FROM ${this.table} WHERE tbl = ? AND k = ?`, tbl, key)[0]
    return r ? { key: r.k, n: r.n === null ? null : Number(r.n), row: JSON.parse(r.json) as T } : undefined
  }

  range<T>(tbl: string, q: RowRange): Array<StoredRow<T>> {
    const limit = Math.max(0, Math.min(q.limit, 1000))
    return this.sql
      .exec<{ k: string; n: number | null; json: string }>(
        `SELECT k, n, json FROM ${this.table} WHERE tbl = ? AND n IS NOT NULL AND n > ? AND n < ? ORDER BY n ${q.desc ? "DESC" : "ASC"} LIMIT ?`,
        tbl,
        q.after ?? Number.MIN_SAFE_INTEGER,
        q.before ?? Number.MAX_SAFE_INTEGER,
        limit
      )
      .map((r) => ({ key: r.k, n: r.n === null ? null : Number(r.n), row: JSON.parse(r.json) as T }))
  }

  /** Called by the engine inside its commit transaction. */
  apply(writes: ReadonlyArray<RowWrite>): void {
    for (const w of writes) {
      if (w.op === "delete") this.sql.exec(`DELETE FROM ${this.table} WHERE tbl = ? AND k = ?`, w.table, w.key)
      else {
        if (w.n !== undefined && w.n !== null) {
          const clash = this.sql.exec<{ k: string }>(`SELECT k FROM ${this.table} WHERE tbl = ? AND n = ? AND k != ?`, w.table, w.n, w.key)[0]
          if (clash) throw new Error(`row order ${w.n} in ${w.table} already belongs to ${clash.k}`)
        }
        this.sql.exec(
          `INSERT INTO ${this.table} (tbl, k, n, json) VALUES (?, ?, ?, ?) ON CONFLICT (tbl, k) DO UPDATE SET n = excluded.n, json = excluded.json`,
          w.table,
          w.key,
          w.n ?? null,
          JSON.stringify(w.row)
        )
      }
    }
  }

  /** Deletes up to `limit` ordered rows with n < before (retention). */
  pruneBefore(tbl: string, before: number, limit: number): Array<string> {
    const keys = this.sql.exec<{ k: string }>(`SELECT k FROM ${this.table} WHERE tbl = ? AND n IS NOT NULL AND n < ? ORDER BY n LIMIT ?`, tbl, before, limit).map((r) => r.k)
    for (const k of keys) this.sql.exec(`DELETE FROM ${this.table} WHERE tbl = ? AND k = ?`, tbl, k)
    return keys
  }
}

/**
 * Rows a client holds (the loaded pages of a mirror). Applying committed writes keeps it
 * equal to the owner on the keys it has; it never invents rows it was not sent.
 */
export class MemoryRows implements RowReader {
  private readonly tables = new Map<string, Map<string, StoredRow>>()

  get<T>(tbl: string, key: string): StoredRow<T> | undefined {
    return this.tables.get(tbl)?.get(key) as StoredRow<T> | undefined
  }

  range<T>(tbl: string, q: RowRange): Array<StoredRow<T>> {
    const all = [...(this.tables.get(tbl)?.values() ?? [])].filter(
      (r) => r.n !== null && r.n > (q.after ?? Number.MIN_SAFE_INTEGER) && r.n < (q.before ?? Number.MAX_SAFE_INTEGER)
    )
    all.sort((a, b) => (q.desc ? b.n! - a.n! : a.n! - b.n!))
    return all.slice(0, q.limit) as Array<StoredRow<T>>
  }

  apply(writes: ReadonlyArray<RowWrite>): void {
    for (const w of writes) {
      const t = this.tables.get(w.table) ?? new Map<string, StoredRow>()
      this.tables.set(w.table, t)
      if (w.op === "delete") t.delete(w.key)
      else t.set(w.key, { key: w.key, n: w.n ?? null, row: w.row })
    }
  }

  load(table: string, rows: ReadonlyArray<StoredRow>): void {
    this.apply(rows.map((r) => ({ table, op: "upsert" as const, key: r.key, n: r.n, row: r.row })))
  }

  /** Every row, for invariant checks. */
  dump(): Record<string, Record<string, StoredRow>> {
    return Object.fromEntries([...this.tables].map(([t, m]) => [t, Object.fromEntries(m)]))
  }

  clear(): void {
    this.tables.clear()
  }
}

/** Base rows with pending writes on top (a client's visible rows = mirror rows + intents). */
export class OverlayRows implements RowReader {
  private readonly top = new Map<string, Map<string, StoredRow | null>>()

  constructor(private readonly base: RowReader) {}

  get<T>(tbl: string, key: string): StoredRow<T> | undefined {
    const o = this.top.get(tbl)
    if (o?.has(key)) return (o.get(key) ?? undefined) as StoredRow<T> | undefined
    return this.base.get<T>(tbl, key)
  }

  range<T>(tbl: string, q: RowRange): Array<StoredRow<T>> {
    const o = this.top.get(tbl)
    if (!o || o.size === 0) return this.base.range<T>(tbl, q)
    const inRange = (n: number | null) => n !== null && n > (q.after ?? Number.MIN_SAFE_INTEGER) && n < (q.before ?? Number.MAX_SAFE_INTEGER)
    const merged = new Map<string, StoredRow>()
    for (const r of this.base.range(tbl, { ...q, limit: q.limit + o.size })) if (!o.has(r.key)) merged.set(r.key, r)
    for (const [k, r] of o) if (r && inRange(r.n)) merged.set(k, r)
    return [...merged.values()].sort((a, b) => (q.desc ? b.n! - a.n! : a.n! - b.n!)).slice(0, q.limit) as Array<StoredRow<T>>
  }

  apply(writes: ReadonlyArray<RowWrite>): void {
    for (const w of writes) {
      const t = this.top.get(w.table) ?? new Map<string, StoredRow | null>()
      this.top.set(w.table, t)
      t.set(w.key, w.op === "delete" ? null : { key: w.key, n: w.n ?? null, row: w.row })
    }
  }
}
