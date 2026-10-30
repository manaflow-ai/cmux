/**
 * The full Postgres/MySQL verify (cmuxterm-hq#4767 step 5) as a read-only pass over every row of every
 * projected table, for the API Worker's hourly cron (apps/api/src/projection-compare-full-cron.ts).
 *
 * Each side is read by keyset pages in key order (Postgres COLLATE "C", MySQL ascii_bin, numeric keys as
 * numbers) and the two sorted streams are merged: a key only one side has, or a key whose row hash
 * differs, is a suspect. Suspects are read again by key at the end of the table, and only those that
 * still differ are reported, so a row written to the primary while the shadow catches up is not a
 * difference. Junk teams are left out on both sides, as the 5,000-row compare does (cmux#26748): a row
 * whose team column (TEAM_COLUMN) names a junk team is dropped as it is read, and a row with no team
 * stays. (Dropped here rather than in SQL, so no query carries the list of junk teams.)
 *
 * No snapshot: keys never change, so every row that exists for the whole pass is read on both sides
 * and compared. A row written while the pass runs may be read on one side only or in two states; that
 * is a suspect, settled by the recheck. A row inserted behind the cursor on both sides is not seen
 * until the next pass.
 *
 * Reads only. Both database handles go through `selectOnly`, which refuses any statement that is not a
 * single SELECT, and nothing here takes a MySQL writer: the full pass never repairs, whatever the primary is.
 */
import { NUMERIC_KEYS, PROJECTION_TABLES, TEAM_COLUMN, rowHash, shapeRow, sharedColumns, type MyLike, type PgLike } from "./projection-compare.ts"

type Row = Record<string, unknown>
type Key = ReadonlyArray<string | number>

/** A database handle that runs single SELECT statements only; anything else, or a second statement after a `;`, is refused before it reaches the database. */
const isSelect = (sql: string) => /^\s*select\s/i.test(sql) && !sql.includes(";")
export const selectOnlyPg = (db: PgLike): PgLike => ({
  query: (sql, values) => (isSelect(sql) ? db.query(sql, values) : Promise.reject(new Error(`full compare is read-only: refused ${sql.trim().split(/\s/)[0]}`)))
})
export const selectOnlyMy = (db: MyLike): MyLike => ({
  query: (sql, values) => (isSelect(sql) ? db.query(sql, values) : Promise.reject(new Error(`full compare is read-only: refused ${sql.trim().split(/\s/)[0]}`)))
})

/** The pass stopped at its per-invocation bound (rows read or wall time); the table it was in is incomplete. */
export class FullCompareBudgetExceeded extends Error {}
/** A side returned keys out of order, or a numeric key past 2^53, so the merge cannot give a verdict for this table. */
export class FullCompareOrderError extends Error {}

export interface FullBudget {
  /** Rows read so far in this invocation, both sides, rechecks included. */
  rowsRead: number
  readonly maxRows: number
  /** Date.now() past which no new page is read. */
  readonly deadline: number
  readonly now?: () => number
}

export interface FullTableReport {
  readonly table: string
  readonly postgresRows: number
  readonly mysqlRows: number
  /** Distinct keys seen on either side. */
  readonly rowsChecked: number
  readonly pages: number
  readonly missingInMysql: Array<string>
  readonly missingInPostgres: Array<string>
  readonly changed: Array<string>
  /** Suspects past `recheckCap`, not read again; each one counts as a difference. */
  readonly unchecked: number
}
export const fullDiffCount = (r: FullTableReport) => r.missingInMysql.length + r.missingInPostgres.length + r.changed.length + r.unchecked

export interface FullTableOptions {
  readonly excludeTeams: ReadonlyArray<string>
  readonly budget: FullBudget
  readonly pageSize?: number
  /** Suspects read again by key at most (memory); more are counted as unchecked differences. */
  readonly recheckCap?: number
  /** Test seam: runs before the recheck. */
  readonly beforeRecheck?: () => Promise<void>
}

/** Key order of both databases for ASCII ids (byte order) and numeric keys (n, seq). */
const compareKeys = (a: Key, b: Key): number => {
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!
    const y = b[i]!
    if (x === y) continue
    // Text keys are ASCII ids (ascii_bin), so UTF-16 order is byte order; numeric keys compare as numbers.
    return typeof x === "number" && typeof y === "number" ? (x < y ? -1 : 1) : String(x) < String(y) ? -1 : 1
  }
  return 0
}

const charge = (budget: FullBudget, rows: number) => {
  budget.rowsRead += rows
}
const checkBudget = (budget: FullBudget) => {
  if (budget.rowsRead >= budget.maxRows || (budget.now ?? Date.now)() >= budget.deadline) throw new FullCompareBudgetExceeded("full compare budget reached")
}

/**
 * The keyset condition `key > after` in lexicographic order: `(k1 > a1) OR (k1 = a1 AND k2 > a2) ...`.
 * `cmp` renders one comparison of column `k` with the placeholder for `value`.
 */
const afterCondition = (keys: ReadonlyArray<string>, after: Key, cmp: (k: string, op: ">" | "=", value: unknown) => string): string =>
  `(${keys.map((_, i) => `(${[...keys.slice(0, i).map((k, j) => cmp(k, "=", after[j])), cmp(keys[i]!, ">", after[i])].join(" AND ")})`).join(" OR ")})`

interface Side {
  page(after: Key | null, limit: number): Promise<Array<Row>>
  byKeys(keys: ReadonlyArray<Key>): Promise<Array<Row>>
}

const pgSide = (pgc: PgLike, table: string, keys: ReadonlyArray<string>, columns: ReadonlyArray<string>): Side => {
  const order = keys.map((k) => (NUMERIC_KEYS.has(k) ? `"${k}"` : `"${k}" COLLATE "C"`)).join(", ")
  // now() is not an immutable function, so Hyperdrive never answers these reads from its query cache.
  const select = `SELECT now() AS uncached_at, ${columns.map((c) => `"${c}"`).join(", ")} FROM ${table}`
  return {
    page: async (after, limit) => {
      const values: Array<unknown> = []
      const where = after ? ` WHERE ${afterCondition(keys, after, (k, op, v) => (values.push(v), NUMERIC_KEYS.has(k) || op === "=" ? `"${k}" ${op} $${values.length}` : `"${k}" COLLATE "C" ${op} $${values.length}`))}` : ""
      return (await pgc.query(`${select}${where} ORDER BY ${order} LIMIT ${limit}`, values)).rows
    },
    byKeys: async (wanted) => {
      const values: Array<unknown> = []
      const match = wanted.map((key) => `(${keys.map((k, j) => (values.push(key[j]), `"${k}" = $${values.length}`)).join(" AND ")})`).join(" OR ")
      return (await pgc.query(`${select} WHERE ${match}`, values)).rows
    }
  }
}

const mySide = (my: MyLike, table: string, keys: ReadonlyArray<string>, columns: ReadonlyArray<string>): Side => {
  const order = keys.map((k) => `\`${k}\``).join(", ")
  // NOW(3) keeps Hyperdrive from answering these reads from its query cache.
  const select = `SELECT NOW(3) AS uncached_at, ${columns.map((c) => `\`${c}\``).join(", ")} FROM \`${table}\``
  const rows = async (sql: string, values: Array<unknown>) => ((await my.query(sql, values)) as [Array<Row>])[0]
  return {
    page: async (after, limit) => {
      const values: Array<unknown> = []
      const where = after ? ` WHERE ${afterCondition(keys, after, (k, op, v) => (values.push(v), `\`${k}\` ${op} ?`))}` : ""
      return rows(`${select}${where} ORDER BY ${order} LIMIT ${limit}`, values)
    },
    byKeys: async (wanted) => {
      const values: Array<unknown> = []
      const match = wanted.map((key) => `(${keys.map((k, j) => (values.push(key[j]), `\`${k}\` = ?`)).join(" AND ")})`).join(" OR ")
      return rows(`${select} WHERE ${match}`, values)
    }
  }
}

/** One side read page by page in key order; refuses a key that does not sort after the one before it. */
class KeysetStream {
  private buf: Array<Row> = []
  private i = 0
  private done = false
  private after: Key | null = null
  private last: Key | null = null
  rows = 0
  pages = 0
  constructor(
    private readonly side: Side,
    private readonly keyOf: (r: Row) => Key,
    private readonly keep: (r: Row) => boolean,
    private readonly name: string,
    private readonly pageSize: number,
    private readonly budget: FullBudget
  ) {}
  async peek(): Promise<Row | undefined> {
    // A page of junk-team rows only leaves nothing to merge: read on until a kept row or the end.
    while (this.i >= this.buf.length) {
      if (this.done) return undefined
      checkBudget(this.budget)
      // Never more rows than the bound has left: a short last page is only "done" when it is shorter than asked for.
      const limit = Math.min(this.pageSize, this.budget.maxRows - this.budget.rowsRead)
      const raw = await this.side.page(this.after, limit)
      this.pages += 1
      charge(this.budget, raw.length)
      if (raw.length < limit) this.done = true
      // The cursor moves past every row read, kept or not.
      if (raw.length > 0) this.after = this.keyOf(raw[raw.length - 1]!)
      this.buf = raw.filter(this.keep)
      this.i = 0
    }
    return this.buf[this.i]
  }
  next(): void {
    const key = this.keyOf(this.buf[this.i]!)
    if (this.last && compareKeys(this.last, key) >= 0) throw new FullCompareOrderError(`${this.name} keys out of order`)
    this.last = key
    this.i += 1
    this.rows += 1
  }
}

/**
 * Compares every row of one projected table. Throws FullCompareBudgetExceeded when the invocation's
 * bound is reached first, and FullCompareOrderError when a side's key order disagrees with the merge's.
 */
export const compareTableFull = async (pgc: PgLike, my: MyLike, table: string, options: FullTableOptions): Promise<FullTableReport> => {
  const spec = PROJECTION_TABLES[table]
  if (!spec) throw new Error(`not a projected table: ${table}`)
  const pageSize = options.pageSize ?? 1000
  const recheckCap = options.recheckCap ?? 20_000
  // A table that starts past the bound reads nothing, not even its column lists.
  checkBudget(options.budget)
  const shared = (await sharedColumns(pgc, my, table)).filter((c) => !spec.skip.includes(c))
  const teamColumn = TEAM_COLUMN[table]
  const columns = [...new Set([...spec.key, ...(teamColumn ? [teamColumn] : []), ...shared])]
  const junk = new Set(options.excludeTeams)
  // As pgScope/myScope in projection-compare.ts: a row of a junk team is left out, a row with no team stays.
  const keep = (r: Row) => !teamColumn || r[teamColumn] === null || r[teamColumn] === undefined || !junk.has(String(r[teamColumn]))
  const keyOf = (r: Row): Key =>
    spec.key.map((k) => {
      if (!NUMERIC_KEYS.has(k)) return String(r[k])
      const n = Number(r[k])
      // A bigint past 2^53 would collide with its neighbours as a number: no verdict rather than a wrong one.
      if (!Number.isSafeInteger(n) || String(n) !== String(r[k])) throw new FullCompareOrderError(`${table}.${k}: not a safe integer key`)
      return n
    })
  const keyText = (key: Key) => key.map(String).join("/")
  // Numeric keys hash in one form: Postgres returns a bigint as text, mysql2 as a number, and norm() keeps text of 16+ digits as text.
  const hashOf = (r: Row) => rowHash({ ...shapeRow(r, shared), ...Object.fromEntries(spec.key.filter((k) => NUMERIC_KEYS.has(k)).map((k) => [k, String(r[k])])) })
  const pgSideT = pgSide(pgc, table, spec.key, columns)
  const mySideT = mySide(my, table, spec.key, columns)
  const pgStream = new KeysetStream(pgSideT, keyOf, keep, "postgres", pageSize, options.budget)
  const myStream = new KeysetStream(mySideT, keyOf, keep, "mysql", pageSize, options.budget)

  const suspects: Array<Key> = []
  let unchecked = 0
  let checked = 0
  const suspect = (key: Key) => (suspects.length < recheckCap ? suspects.push(key) : (unchecked += 1))
  for (;;) {
    const a = await pgStream.peek()
    const b = await myStream.peek()
    if (!a && !b) break
    const c = !a ? 1 : !b ? -1 : compareKeys(keyOf(a), keyOf(b))
    checked += 1
    if (c < 0) {
      suspect(keyOf(a!))
      pgStream.next()
    } else if (c > 0) {
      suspect(keyOf(b!))
      myStream.next()
    } else {
      if (hashOf(a!) !== hashOf(b!)) suspect(keyOf(a!))
      pgStream.next()
      myStream.next()
    }
  }

  const missingInMysql: Array<string> = []
  const missingInPostgres: Array<string> = []
  const changed: Array<string> = []
  if (suspects.length > 0) {
    await options.beforeRecheck?.()
    for (let i = 0; i < suspects.length; ) {
      checkBudget(options.budget)
      // At most one row per key and side: a batch never reads past the bound.
      const room = Math.floor((options.budget.maxRows - options.budget.rowsRead) / 2)
      if (room < 1) throw new FullCompareBudgetExceeded("full compare budget reached")
      const slice = suspects.slice(i, i + Math.min(200, room))
      i += slice.length
      const [pgRows, myRows] = [await pgSideT.byKeys(slice), await mySideT.byKeys(slice)]
      charge(options.budget, pgRows.length + myRows.length)
      const pgHash = new Map(pgRows.filter(keep).map((r) => [keyText(keyOf(r)), hashOf(r)]))
      const myHash = new Map(myRows.filter(keep).map((r) => [keyText(keyOf(r)), hashOf(r)]))
      for (const key of slice.map(keyText)) {
        const p = pgHash.get(key)
        const m = myHash.get(key)
        if (p !== undefined && m === undefined) missingInMysql.push(key)
        else if (p === undefined && m !== undefined) missingInPostgres.push(key)
        else if (p !== undefined && p !== m) changed.push(key)
      }
    }
  }
  return {
    table,
    postgresRows: pgStream.rows,
    mysqlRows: myStream.rows,
    rowsChecked: checked,
    pages: pgStream.pages + myStream.pages,
    missingInMysql: missingInMysql.sort(),
    missingInPostgres: missingInPostgres.sort(),
    changed: changed.sort(),
    unchecked
  }
}
