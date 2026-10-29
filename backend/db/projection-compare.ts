/**
 * Shared by the Postgres/MySQL parity test and the copy/verify job (state-placement.md 4.5): the
 * projected tables, their keys, the columns that legitimately differ (defaults set by each server),
 * and one normalization so a row from either database compares equal when it holds the same facts.
 */
import { createHash } from "node:crypto"

export const PROJECTION_TABLES: Record<string, { readonly key: ReadonlyArray<string>; readonly skip: ReadonlyArray<string> }> = {
  users: { key: ["id"], skip: ["created_at", "updated_at"] },
  teams: { key: ["id"], skip: ["created_at", "updated_at"] },
  installs: { key: ["id"], skip: ["updated_at"] },
  memberships: { key: ["team_id", "user_id"], skip: ["updated_at"] },
  hosts: { key: ["id"], skip: ["updated_at", "deleted_at"] },
  automations: { key: ["id"], skip: ["deleted_at"] },
  automation_runs: { key: ["id"], skip: ["updated_at"] },
  connections: { key: ["id"], skip: [] },
  audit_events: { key: ["team_id", "n"], skip: ["created_at"] },
  home_conversations: { key: ["id"], skip: ["updated_at"] },
  home_participants: { key: ["conversation_id", "participant_id"], skip: ["updated_at"] },
  home_invites: { key: ["id"], skip: ["updated_at"] },
  home_message_search: { key: ["conversation_id", "seq"], skip: [] }
}

const sortKeys = (v: unknown): unknown =>
  Array.isArray(v) ? v.map(sortKeys) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v as object).sort().map((k) => [k, sortKeys((v as Record<string, unknown>)[k])])) : v

/** One comparable value: times as epoch ms, JSON canonical, integers as numbers, booleans as 0/1. */
export const norm = (v: unknown): unknown => {
  if (v === null || v === undefined) return null
  if (v instanceof Date) return v.getTime()
  if (typeof v === "boolean") return v ? 1 : 0
  if (typeof v === "string" && /^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}/.test(v)) return Date.parse(v.includes("T") ? v : `${v.replace(" ", "T")}Z`)
  if (typeof v === "string" && /^-?\d+$/.test(v) && v.length < 16) return Number(v)
  if (typeof v === "object") return JSON.stringify(sortKeys(v))
  return v
}

/** A row's comparable shape over the given columns. */
export const shapeRow = (row: Record<string, unknown>, columns: ReadonlyArray<string>): Record<string, unknown> => Object.fromEntries(columns.map((c) => [c, norm(row[c])]))

/** sha256 of the canonical JSON of a shaped row. */
export const rowHash = (shaped: Record<string, unknown>): string => createHash("sha256").update(JSON.stringify(sortKeys(shaped))).digest("hex")

/** A MySQL datetime(3) literal (UTC) from a Date; other values unchanged; objects as JSON text. */
export const toMysqlValue = (v: unknown): unknown => {
  if (v instanceof Date) return v.toISOString().replace("T", " ").replace("Z", "")
  if (v !== null && typeof v === "object") return JSON.stringify(v)
  return v
}

/**
 * Junk teams (cmuxterm-hq#4767 step 1): the sign-up personal teams of cmux.com visitors that Stack
 * signed up anonymously, which the Stack webhook mirrored before the fix in team-stack-sync.ts
 * (anonymous_team_ignored). Stack's anonymous flag is not in the projection, so the rule reads what
 * is, and a team that fails any part is kept:
 * - Stack's default name for a personal team whose owner has no display name, "Personal Team" (an
 *   anonymous user has none; a named user's team is "<name>'s Team");
 * - no member with a `users` row: auth.ts refuses anonymous tokens, so an anonymous user never
 *   gets one;
 * - never used: no hosts, automations, runs, connections or conversations.
 * The copy skips these teams and their team-scoped rows instead of deleting them on Postgres, and
 * verify and the compare cron leave them out on both sides. The TeamDO stays the source of truth: a
 * kept-out team that changes later is projected again by its next outbox write.
 */
export const JUNK_TEAMS_SQL = `SELECT t.id FROM teams t WHERE t.kind = 'stack' AND t.display_name = 'Personal Team'
  AND NOT EXISTS (SELECT 1 FROM memberships m JOIN users u ON u.id = m.user_id WHERE m.team_id = t.id)
  AND NOT EXISTS (SELECT 1 FROM hosts x WHERE x.team_id = t.id)
  AND NOT EXISTS (SELECT 1 FROM automations x WHERE x.team_id = t.id)
  AND NOT EXISTS (SELECT 1 FROM automation_runs x WHERE x.team_id = t.id)
  AND NOT EXISTS (SELECT 1 FROM connections x WHERE x.team_id = t.id)
  AND NOT EXISTS (SELECT 1 FROM home_conversations x WHERE x.team_id = t.id)
  ORDER BY t.id COLLATE "C"`

/** The ids of the junk teams in the Postgres projection (JUNK_TEAMS_SQL). Reads only. */
export const junkTeams = async (pgc: PgLike): Promise<Array<string>> => (await pgc.query(JUNK_TEAMS_SQL)).rows.map((r) => String(r.id))

/** The column that names the owning team, for the tables whose rows belong to one team. */
export const TEAM_COLUMN: Readonly<Record<string, string>> = {
  teams: "id",
  memberships: "team_id",
  hosts: "team_id",
  automations: "team_id",
  automation_runs: "team_id",
  connections: "team_id",
  audit_events: "team_id",
  home_conversations: "team_id"
}

/** A Postgres WHERE clause that leaves out the rows of `exclude` teams (a row with no team stays). */
const pgScope = (table: string, exclude: ReadonlyArray<string>, values: Array<unknown>): string => {
  const col = TEAM_COLUMN[table]
  if (!col || exclude.length === 0) return ""
  values.push([...exclude])
  return ` WHERE ("${col}" IS NULL OR NOT ("${col}" = ANY($${values.length}::text[])))`
}
/** The MySQL form of pgScope. */
const myScope = (table: string, exclude: ReadonlyArray<string>, values: Array<unknown>): string => {
  const col = TEAM_COLUMN[table]
  if (!col || exclude.length === 0) return ""
  values.push(...exclude)
  return ` WHERE (\`${col}\` IS NULL OR \`${col}\` NOT IN (${exclude.map(() => "?").join(", ")}))`
}

/** Key columns that are numbers, not ASCII ids. */
export const NUMERIC_KEYS: ReadonlySet<string> = new Set(["n", "seq"])

export interface PgLike {
  query(sql: string, values?: Array<unknown>): Promise<{ rows: Array<Record<string, unknown>> }>
}
export interface MyLike {
  query(sql: string, values?: Array<unknown>): Promise<unknown>
}

const mysqlColumns = async (my: MyLike, table: string): Promise<Array<string>> => {
  const [rows] = (await my.query("SELECT column_name AS c FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table])) as [Array<{ c: string }>]
  return rows.map((r) => r.c)
}
const pgColumns = async (pgc: PgLike, table: string): Promise<Set<string>> =>
  new Set((await pgc.query("SELECT column_name AS c FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = $1 AND is_generated = 'NEVER'", [table])).rows.map((r) => String(r.c)))

/** The columns both databases have (Postgres-only columns such as the tsvector are left out). */
export const sharedColumns = async (pgc: PgLike, my: MyLike, table: string) => {
  const inPg = await pgColumns(pgc, table)
  return (await mysqlColumns(my, table)).filter((c) => inPg.has(c))
}

export interface TableReport {
  readonly table: string
  readonly equal: boolean
  readonly pgCount: number
  readonly mysqlCount: number
  /** More rows than the bound: counts compared, rows only for the first maxRows keys. */
  readonly partial: boolean
  readonly missingInMysql: Array<string>
  readonly missingInPostgres: Array<string>
  readonly changed: Array<string>
}

/**
 * Compares the given tables (all by default). Rows are read in byte order of the key on both sides
 * (Postgres COLLATE "C", MySQL ascii_bin keys) and at most `maxRows` per table: a larger table
 * compares its counts and the first `maxRows` keys, and the report says `partial`. The rows of the
 * `excludeTeams` teams (TEAM_COLUMN) are left out on both sides, counts included.
 */
export const verifyTables = async (
  pgc: PgLike,
  my: MyLike,
  options: { readonly maxRows?: number; readonly tables?: ReadonlyArray<string>; readonly excludeTeams?: ReadonlyArray<string> } = {}
): Promise<Array<TableReport>> => {
  const out: Array<TableReport> = []
  const limit = options.maxRows ?? 1_000_000
  const exclude = options.excludeTeams ?? []
  for (const [table, spec] of Object.entries(PROJECTION_TABLES)) {
    if (options.tables && !options.tables.includes(table)) continue
    const columns = (await sharedColumns(pgc, my, table)).filter((c) => !spec.skip.includes(c))
    const keyOf = (r: Record<string, unknown>) => spec.key.map((k) => String(r[k])).join("/")
    // Text keys sort in byte order like MySQL ascii_bin; the numeric keys (n, seq) sort as numbers on both.
    const pgOrder = spec.key.map((k) => (NUMERIC_KEYS.has(k) ? `"${k}"` : `"${k}" COLLATE "C"`)).join(", ")
    const myOrder = spec.key.map((k) => `\`${k}\``).join(", ")
    const pgValues: Array<unknown> = []
    const pgWhere = pgScope(table, exclude, pgValues)
    const myValues: Array<unknown> = []
    const myWhere = myScope(table, exclude, myValues)
    const pgRows = (await pgc.query(`SELECT ${columns.map((c) => `"${c}"`).join(", ")} FROM ${table}${pgWhere} ORDER BY ${pgOrder} LIMIT ${limit}`, pgValues)).rows
    const [myRows] = (await my.query(`SELECT ${columns.map((c) => `\`${c}\``).join(", ")} FROM \`${table}\`${myWhere} ORDER BY ${myOrder} LIMIT ${limit}`, myValues)) as [Array<Record<string, unknown>>]
    const pgCount = Number((await pgc.query(`SELECT count(*) AS n FROM ${table}${pgWhere}`, pgValues)).rows[0]?.n ?? 0)
    const [[myCountRow]] = (await my.query(`SELECT count(*) AS n FROM \`${table}\`${myWhere}`, myValues)) as [Array<{ n: number | string }>]
    const mysqlCount = Number(myCountRow?.n ?? 0)
    const partial = pgCount > limit || mysqlCount > limit
    const pgHash = new Map(pgRows.map((r) => [keyOf(r), rowHash(shapeRow(r, columns))]))
    const myHash = new Map(myRows.map((r) => [keyOf(r), rowHash(shapeRow(r, columns))]))
    const missingInMysql = [...pgHash.keys()].filter((k) => !myHash.has(k)).sort()
    const missingInPostgres = [...myHash.keys()].filter((k) => !pgHash.has(k)).sort()
    const changed = [...pgHash.keys()].filter((k) => myHash.has(k) && myHash.get(k) !== pgHash.get(k)).sort()
    out.push({ table, equal: pgCount === mysqlCount && missingInMysql.length + missingInPostgres.length + changed.length === 0, pgCount, mysqlCount, partial, missingInMysql, missingInPostgres, changed })
  }
  return out
}

/**
 * The guarded MySQL upsert for one projected table (the projection's single-writer rule): a row
 * already at a newer `source_seq` keeps its values, so a copy or repair never moves a row back.
 */
export const guardedUpsertMysql = (table: string, columns: ReadonlyArray<string>, rowCount: number): string => {
  const keys = new Set(PROJECTION_TABLES[table]!.key)
  const set = [
    ...columns.filter((c) => !keys.has(c) && c !== "source_seq").map((c) => `\`${c}\` = IF(\`source_seq\` <= VALUES(\`source_seq\`), VALUES(\`${c}\`), \`${c}\`)`),
    "`source_seq` = GREATEST(`source_seq`, VALUES(`source_seq`))"
  ].join(", ")
  const placeholders = Array.from({ length: rowCount }, () => `(${columns.map(() => "?").join(", ")})`).join(", ")
  return `INSERT INTO \`${table}\` (${columns.map((c) => `\`${c}\``).join(", ")}) VALUES ${placeholders} ON DUPLICATE KEY UPDATE ${set}`
}

/**
 * Copies the rows with the given report keys (`a/b` as in ``TableReport``) from Postgres into
 * MySQL through ``guardedUpsertMysql``. Reads Postgres only; never deletes. Returns the number of
 * Postgres rows sent (a key gone from Postgres meanwhile is skipped).
 */
export const copyKeysToMysql = async (pgc: PgLike, my: MyLike, table: string, keys: ReadonlyArray<string>, batch = 200): Promise<number> => {
  const spec = PROJECTION_TABLES[table]
  if (!spec || keys.length === 0) return 0
  const columns = await sharedColumns(pgc, my, table)
  let sent = 0
  for (let i = 0; i < keys.length; i += batch) {
    const slice = keys.slice(i, i + batch).map((k) => k.split("/"))
    if (slice.some((parts) => parts.length !== spec.key.length)) throw new Error(`projection key shape: ${table}`)
    const values: Array<unknown> = []
    const where = slice.map((parts) => `(${spec.key.map((k, j) => { values.push(NUMERIC_KEYS.has(k) ? Number(parts[j]) : parts[j]); return `"${k}" = $${values.length}` }).join(" AND ")})`).join(" OR ")
    const rows = (await pgc.query(`SELECT ${columns.map((c) => `"${c}"`).join(", ")} FROM ${table} WHERE ${where}`, values)).rows
    if (rows.length === 0) continue
    await my.query(guardedUpsertMysql(table, columns, rows.length), rows.flatMap((r) => columns.map((c) => toMysqlValue(r[c]))))
    sent += rows.length
  }
  return sent
}
