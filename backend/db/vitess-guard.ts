/**
 * Rails for PlanetScale Vitess migrations (`drizzle-mysql/`), plans/cmux-next/db-migrations-DESIGN.md.
 *
 * - lintMysqlFile: each file declares `-- phase: expand` or `-- phase: contract`. Expand files hold
 *   only additions the deployed code survives (allowlist, unknown shapes refuse). A contract file
 *   needs `-- contract: <reason>` and holds no expand statement, so expand changes deploy first.
 *   Some changes are never allowed in a migration (drops of tables, renames, data changes).
 * - historyProblems: landed files never change or disappear; new files number above the base; one
 *   push does not add an expand and a contract migration together (they are separate deploys).
 * - pendingForPhase: staging applies expand files before the Worker deploy, contract files after it.
 * - releaseGateProblems / schemaDiff / schemaSnapshot: staging first. A production deploy request
 *   opens only when staging ran every file with the same checksum and the release branch schema
 *   equals the staging schema.
 *
 * The SQL is tokenized (comments, strings and backtick identifiers removed) before any keyword is
 * read, so `DROP/**\/TABLE` or a keyword inside a string or identifier cannot hide a statement.
 */
import { createHash } from "node:crypto"

export type Phase = "expand" | "contract"
type Level = "expand" | "contract" | "never"

/** Files that predate the phase header: exempt from the header only, by exact name and sha256. */
export const GRANDFATHERED: Readonly<Record<string, string>> = {
  "0000_baseline.sql": "647839346a5c98d4384ea0013ec8b9bce1f9eb54639f1856612c2dc37d07b555",
  "0001_credits.sql": "6c2d82dd565e8410e128447a5ef2cbb24d321909d54bbe8dd3e0c84763a41a31"
}

const NAME = /^(\d{4})_[a-z0-9_]+\.sql$/
const MIN_REASON = 10
const sha256 = (text: string) => createHash("sha256").update(text).digest("hex")

interface Token {
  readonly t: "word" | "ident" | "str" | "num" | "punct"
  /** Upper-case for words, the name for identifiers, the character for punctuation. */
  readonly v: string
}

/** Tokens of a SQL text, or an error for an executable or unterminated comment or string. */
const tokenize = (sql: string): { tokens: Array<Token>; error?: string } => {
  const tokens: Array<Token> = []
  let i = 0
  while (i < sql.length) {
    const c = sql[i]!
    if (/\s/.test(c)) i++
    else if ((c === "-" && sql[i + 1] === "-") || c === "#") {
      const end = sql.indexOf("\n", i)
      i = end < 0 ? sql.length : end + 1
    } else if (c === "/" && sql[i + 1] === "*") {
      if (sql[i + 2] === "!" || sql[i + 2] === "+") return { tokens, error: "executable comments (/*! */, /*+ */) are not allowed" }
      const end = sql.indexOf("*/", i + 2)
      if (end < 0) return { tokens, error: "unterminated comment" }
      i = end + 2
    } else if (c === "'" || c === '"' || c === "`") {
      let j = i + 1
      let text = ""
      for (; j < sql.length; j++) {
        if (sql[j] === "\\" && c !== "`") {
          text += sql[j + 1] ?? ""
          j++
        } else if (sql[j] === c) {
          if (sql[j + 1] === c) {
            text += c
            j++
          } else break
        } else text += sql[j]
      }
      if (j >= sql.length) return { tokens, error: "unterminated string or identifier" }
      tokens.push(c === "`" ? { t: "ident", v: text } : { t: "str", v: text })
      i = j + 1
    } else if (/[A-Za-z_]/.test(c)) {
      const m = /^[A-Za-z_][A-Za-z0-9_$]*/.exec(sql.slice(i))![0]
      tokens.push({ t: "word", v: m.toUpperCase() })
      i += m.length
    } else if (/[0-9]/.test(c)) {
      const m = /^[0-9][0-9.eE]*/.exec(sql.slice(i))![0]
      tokens.push({ t: "num", v: m })
      i += m.length
    } else {
      tokens.push({ t: "punct", v: c })
      i++
    }
  }
  return { tokens }
}

/** Split at top-level `sep` punctuation (not inside parentheses). */
const splitTop = (tokens: ReadonlyArray<Token>, sep: string): Array<Array<Token>> => {
  const parts: Array<Array<Token>> = [[]]
  let depth = 0
  for (const tok of tokens) {
    if (tok.t === "punct" && tok.v === "(") depth++
    if (tok.t === "punct" && tok.v === ")") depth--
    if (depth === 0 && tok.t === "punct" && tok.v === sep) parts.push([])
    else parts[parts.length - 1]!.push(tok)
  }
  return parts.filter((p) => p.length > 0)
}

const isWord = (tok: Token | undefined, ...words: Array<string>) => tok?.t === "word" && words.includes(tok.v)
const words = (tokens: ReadonlyArray<Token>) => new Set(tokens.filter((t) => t.t === "word").map((t) => t.v))
const nameAt = (tokens: ReadonlyArray<Token>, i: number): string | undefined => {
  const tok = tokens[i]
  if (!tok || (tok.t !== "ident" && tok.t !== "word")) return undefined
  return tok.v.toLowerCase()
}
/** Index just past a balanced parenthesis group starting at i, or -1. */
const pastGroup = (tokens: ReadonlyArray<Token>, i: number): number => {
  if (tokens[i]?.v !== "(" || tokens[i]?.t !== "punct") return -1
  let depth = 0
  for (let j = i; j < tokens.length; j++) {
    if (tokens[j]!.t === "punct" && tokens[j]!.v === "(") depth++
    if (tokens[j]!.t === "punct" && tokens[j]!.v === ")" && --depth === 0) return j + 1
  }
  return -1
}

interface Finding {
  readonly level: Level
  readonly what: string
}
const never = (what: string): Finding => ({ level: "never", what })
const contractF = (what: string): Finding => ({ level: "contract", what })
const EXPAND: Finding = { level: "expand", what: "" }

/** Index options that may follow an index's column list. */
const indexTailOk = (tail: ReadonlyArray<Token>): boolean => {
  for (let i = 0; i < tail.length; i++) {
    const tok = tail[i]!
    if (isWord(tok, "WITH") && isWord(tail[i + 1], "PARSER") && tail[i + 2]?.t === "word") i += 2
    else if (isWord(tok, "COMMENT") && tail[i + 1]?.t === "str") i += 1
    else if (isWord(tok, "VISIBLE", "INVISIBLE")) continue
    else return false
  }
  return true
}

/** One ALTER TABLE clause. */
const alterClause = (c: ReadonlyArray<Token>): Finding => {
  const [a, b] = c
  const w = words(c)
  if (w.has("REFERENCES") || w.has("FOREIGN") || w.has("CHECK")) return never("foreign keys and CHECK constraints are not allowed (Vitess; the owning DO keeps integrity)")
  if (w.has("PARTITION")) return never("partitions are not allowed (Vitess shards by keyspace)")
  if (isWord(a, "ADD")) {
    if (isWord(b, "INDEX", "KEY", "FULLTEXT", "SPATIAL")) {
      let i = 2
      if (isWord(b, "FULLTEXT", "SPATIAL") && isWord(c[i], "INDEX", "KEY")) i++
      if (c[i]?.t !== "punct") i++ // the index name
      const end = pastGroup(c, i)
      return end > 0 && indexTailOk(c.slice(end)) ? EXPAND : never("ADD INDEX takes only a name, a column list and WITH PARSER/COMMENT")
    }
    if (isWord(b, "PRIMARY")) return never("ADD PRIMARY KEY: every table has its primary key from CREATE TABLE")
    if (isWord(b, "UNIQUE") || (isWord(b, "CONSTRAINT") && w.has("UNIQUE"))) return contractF("a UNIQUE key on an existing table can reject writes from deployed code")
    if (isWord(b, "CONSTRAINT")) return never("ADD CONSTRAINT other than UNIQUE")
    const def = c.slice(isWord(b, "COLUMN") ? 3 : 2)
    if (c[isWord(b, "COLUMN") ? 2 : 1]?.v === "(") return never("ADD COLUMN (a, b): write one ADD COLUMN per column")
    const dw = words(def)
    for (const k of ["PRIMARY", "UNIQUE", "AUTO_INCREMENT", "GENERATED", "AS"]) if (dw.has(k)) return contractF(`ADD COLUMN with ${k} rewrites or constrains existing rows`)
    const notNull = def.some((t, i) => isWord(t, "NOT") && isWord(def[i + 1], "NULL"))
    if (notNull && !dw.has("DEFAULT")) return contractF("ADD COLUMN ... NOT NULL needs a DEFAULT (deployed code does not write the column)")
    return EXPAND
  }
  if (isWord(a, "DROP")) {
    if (isWord(b, "PRIMARY")) return never("DROP PRIMARY KEY (Vitess needs a primary key on every table)")
    return contractF("DROP of a column or index breaks deployed code that still reads it")
  }
  if (isWord(a, "MODIFY")) return contractF("MODIFY changes the column type or nullability under deployed code")
  if (isWord(a, "CHANGE")) {
    const i = isWord(b, "COLUMN") ? 2 : 1
    return nameAt(c, i) === nameAt(c, i + 1) ? contractF("CHANGE changes the column under deployed code") : never("CHANGE that renames a column: add the new column, backfill, then drop the old one")
  }
  if (isWord(a, "ALTER")) return contractF("ALTER COLUMN changes a default under deployed code")
  if (isWord(a, "RENAME")) {
    if (isWord(b, "INDEX", "KEY")) return contractF("RENAME INDEX breaks index hints in deployed code")
    return never("renaming a table or column breaks deployed code: add the new one, backfill, then drop the old one")
  }
  return never(`ALTER TABLE ${c.map((t) => t.v).slice(0, 2).join(" ")} is not an allowed clause`)
}

/** Classify one statement. `created` collects tables created earlier in the same file. */
const classify = (s: ReadonlyArray<Token>, created: Set<string>): Finding => {
  const [a, b] = s
  if (isWord(a, "CREATE")) {
    if (isWord(b, "TABLE")) {
      let i = 2
      if (isWord(s[2], "IF") && isWord(s[3], "NOT") && isWord(s[4], "EXISTS")) i = 5
      const name = nameAt(s, i)
      const end = pastGroup(s, i + 1)
      if (!name || end < 0) return never("CREATE TABLE must be CREATE TABLE name (columns) [options]")
      const body = words(s.slice(i + 1, end))
      if (body.has("REFERENCES") || body.has("FOREIGN") || body.has("CHECK")) return never("foreign keys and CHECK constraints are not allowed (Vitess; the owning DO keeps integrity)")
      if (!s.slice(i + 1, end).some((t, j, arr) => isWord(t, "PRIMARY") && isWord(arr[j + 1], "KEY"))) return never("every table needs a primary key")
      const tail = words(s.slice(end))
      for (const k of tail) if (!["ENGINE", "DEFAULT", "CHARSET", "CHARACTER", "SET", "COLLATE", "COMMENT", "INNODB"].includes(k) && !/^UTF8MB4/.test(k)) return never(`CREATE TABLE option ${k} is not allowed (no PARTITION, LIKE or AS SELECT)`)
      created.add(name)
      return EXPAND
    }
    let i = 1
    const unique = isWord(s[i], "UNIQUE")
    if (isWord(s[i], "UNIQUE", "FULLTEXT", "SPATIAL")) i++
    if (isWord(s[i], "INDEX")) {
      const on = s.findIndex((t) => isWord(t, "ON"))
      const table = on > 0 ? nameAt(s, on + 1) : undefined
      const end = on > 0 ? pastGroup(s, on + 2) : -1
      if (!table || end < 0 || !indexTailOk(s.slice(end))) return never("CREATE INDEX must be CREATE [UNIQUE|FULLTEXT] INDEX name ON table (columns)")
      if (unique && !created.has(table)) return contractF("CREATE UNIQUE INDEX on an existing table can reject writes from deployed code")
      return EXPAND
    }
    return never(`CREATE ${b?.v ?? ""} is not allowed (no views, triggers, routines or events)`)
  }
  if (isWord(a, "ALTER") && isWord(b, "TABLE")) {
    const table = nameAt(s, 2)
    if (!table) return never("ALTER TABLE needs a table name")
    const clauses = splitTop(s.slice(3), ",")
    if (clauses.length === 0) return never("ALTER TABLE without a clause")
    const found = clauses.map(alterClause)
    const worst = found.find((f) => f.level === "never") ?? found.find((f) => f.level === "contract")
    // A table this file created holds no rows and no deployed code reads it yet.
    if (worst?.level === "contract" && created.has(table)) return EXPAND
    return worst ?? EXPAND
  }
  if (isWord(a, "DROP")) {
    if (isWord(b, "INDEX")) return contractF("DROP INDEX breaks deployed code that relies on it")
    return never(`DROP ${b?.v ?? ""} is not allowed in a migration (drop tables only by a written plan and a reviewed deploy request)`)
  }
  if (isWord(a, "INSERT", "UPDATE", "DELETE", "REPLACE")) return never(`${a!.v}: data changes do not belong in a migration (deploy requests carry schema only); backfill with a script in its own deploy`)
  if (isWord(a, "TRUNCATE")) return never("TRUNCATE deletes data")
  if (isWord(a, "RENAME")) return never("RENAME TABLE breaks deployed code: create the new table, backfill, then drop the old one")
  return never(`${a?.v ?? "an empty statement"} is not an allowed migration statement`)
}

/** The phase a file declares in its leading comment lines. */
export const phaseOf = (text: string): Phase | undefined => header(text).phase
const header = (text: string): { phase?: Phase; reason?: string } => {
  const out: { phase?: Phase; reason?: string } = {}
  for (const line of text.split("\n")) {
    const l = line.trim()
    if (l === "") continue
    if (!l.startsWith("--") || l.startsWith("--> statement-breakpoint")) break
    const p = /^--\s*phase:\s*(expand|contract)\s*$/.exec(l)
    if (p) out.phase = p[1] as Phase
    const r = /^--\s*contract:\s*(.*\S)\s*$/.exec(l)
    if (r) out.reason = r[1]
  }
  return out
}

/** Every problem of one migration file; empty means it may land. */
export const lintMysqlFile = (name: string, text: string): Array<string> => {
  const errors: Array<string> = []
  if (!NAME.test(name)) errors.push(`${name}: name must be NNNN_lower_snake.sql`)
  const grandfathered = GRANDFATHERED[name] === sha256(text)
  const h = header(text)
  const phase: Phase | undefined = h.phase ?? (grandfathered ? "expand" : undefined)
  if (!phase) errors.push(`${name}: the first lines must declare "-- phase: expand" or "-- phase: contract"`)
  if (phase === "contract" && (h.reason ?? "").length < MIN_REASON) errors.push(`${name}: a contract migration needs a "-- contract: <reason>" line (${MIN_REASON}+ characters: what stopped using it, and in which deploy)`)
  const { tokens, error } = tokenize(text)
  if (error) return [...errors, `${name}: ${error}`]
  const created = new Set<string>()
  let contractCount = 0
  for (const stmt of splitTop(tokens, ";")) {
    const f = classify(stmt, created)
    const head = stmt.slice(0, 3).map((t) => t.v).join(" ")
    if (f.level === "never") errors.push(`${name}: ${head}: ${f.what}`)
    else if (f.level === "contract") {
      contractCount++
      if (phase !== "contract") errors.push(`${name}: ${head}: ${f.what}; this is a contract change: put it in its own "-- phase: contract" migration, deployed after the code stops using it`)
    } else if (phase === "contract") errors.push(`${name}: ${head}: an expand change in a contract file; put it in its own expand migration so it deploys first`)
  }
  if (phase === "contract" && contractCount === 0 && errors.length === 0) errors.push(`${name}: a contract file with no contract change; mark it "-- phase: expand"`)
  return errors
}

/**
 * Append-only history: `base` and `head` map file name to content (or hash). Landed files never
 * change or disappear; new files number above the base and do not reuse a number; one push does not
 * add both an expand and a contract migration.
 */
export const historyProblems = (base: Readonly<Record<string, string>>, head: Readonly<Record<string, string>>): Array<string> => {
  const problems: Array<string> = []
  for (const [f, text] of Object.entries(base)) {
    if (!(f in head)) problems.push(`${f}: removed after it landed; migrations are append-only`)
    else if (head[f] !== text) problems.push(`${f}: changed after it landed; add a new numbered file instead`)
  }
  const num = (f: string) => Number(f.slice(0, 4))
  const top = Math.max(-1, ...Object.keys(base).map(num))
  const added = Object.keys(head).filter((f) => !(f in base)).sort()
  for (const f of added) if (num(f) <= top) problems.push(`${f}: new files must number above ${String(top).padStart(4, "0")}`)
  const numbers = Object.keys(head).map(num)
  if (new Set(numbers).size !== numbers.length) problems.push("two migrations share a number")
  const phases = new Set(added.map((f) => phaseOf(head[f]!) ?? "expand"))
  if (phases.has("expand") && phases.has("contract")) problems.push(`one push adds expand and contract migrations (${added.join(", ")}); they must be separate deploys: land the expand and the code first, the contract later`)
  return problems
}

/** The pending files to apply in a phase: "expand" stops before the first contract file. */
export const pendingForPhase = <M extends { readonly text: string }>(pending: ReadonlyArray<M>, phase: "expand" | "all"): Array<M> => {
  if (phase === "all") return [...pending]
  const stop = pending.findIndex((m) => phaseOf(m.text) === "contract")
  return stop < 0 ? [...pending] : pending.slice(0, stop)
}

/** Tables of a branch: column and index descriptions, sorted. `schema_migrations` is left out. */
export type SchemaSnapshot = Record<string, { readonly columns: ReadonlyArray<string>; readonly indexes: ReadonlyArray<string> }>

/** Differences between staging and a release branch, one line each. */
export const schemaDiff = (staging: SchemaSnapshot, release: SchemaSnapshot): Array<string> => {
  const out: Array<string> = []
  for (const t of [...new Set([...Object.keys(staging), ...Object.keys(release)])].sort()) {
    const s = staging[t]
    const r = release[t]
    if (!r) out.push(`table ${t}: only on staging`)
    else if (!s) out.push(`table ${t}: only on release`)
    else
      for (const kind of ["columns", "indexes"] as const) {
        const rs = new Set(r[kind])
        const ss = new Set(s[kind])
        for (const x of s[kind]) if (!rs.has(x)) out.push(`table ${t} ${kind.slice(0, -1)} "${x}": only on staging`)
        for (const x of r[kind]) if (!ss.has(x)) out.push(`table ${t} ${kind.slice(0, -1)} "${x}": only on release`)
      }
  }
  return out
}

/** The staging-first gate of a production deploy request. Empty means it may open. */
export const releaseGateProblems = (input: {
  readonly migrations: ReadonlyArray<{ readonly name: string; readonly checksum: string }>
  readonly stagingHistory: ReadonlyMap<string, string>
  readonly stagingSchema: SchemaSnapshot
  readonly releaseSchema: SchemaSnapshot
}): Array<string> => {
  const problems: Array<string> = []
  for (const m of input.migrations) {
    const ran = input.stagingHistory.get(m.name)
    if (ran === undefined) problems.push(`staging has not run ${m.name}; every migration runs on staging before a production deploy request`)
    else if (ran !== m.checksum) problems.push(`${m.name}: staging ran another checksum; staging must run the exact file`)
  }
  const names = new Set(input.migrations.map((m) => m.name))
  for (const n of input.stagingHistory.keys()) if (!names.has(n)) problems.push(`staging has ${n}, which this tree lacks; release from a commit that has it`)
  for (const d of schemaDiff(input.stagingSchema, input.releaseSchema)) problems.push(`release branch differs from staging: ${d}`)
  return problems
}

interface Queryable {
  query(sql: string): Promise<unknown>
}

/** Read a branch's tables, columns and indexes from information_schema. */
export const schemaSnapshot = async (conn: Queryable): Promise<SchemaSnapshot> => {
  const [cols] = (await conn.query(
    "SELECT TABLE_NAME t, COLUMN_NAME c, COLUMN_TYPE ty, IS_NULLABLE n, COLUMN_DEFAULT d, EXTRA x, COLLATION_NAME co FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, ORDINAL_POSITION"
  )) as [Array<Record<string, string | null>>]
  const [idx] = (await conn.query(
    "SELECT TABLE_NAME t, INDEX_NAME i, NON_UNIQUE nu, INDEX_TYPE ty, COLUMN_NAME c, SEQ_IN_INDEX q FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = DATABASE() ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX"
  )) as [Array<Record<string, string | number | null>>]
  const out: Record<string, { columns: Array<string>; indexes: Array<string> }> = {}
  const tableOf = (t: string) => (out[t] ??= { columns: [], indexes: [] })
  for (const r of cols) {
    if (r.t === "schema_migrations") continue
    tableOf(r.t!).columns.push([r.c, r.ty, r.n, r.d === null ? "" : `default=${r.d}`, r.x ?? "", r.co ?? ""].filter(Boolean).join(" "))
  }
  const grouped = new Map<string, { nu: number; ty: string; cols: Array<string> }>()
  for (const r of idx) {
    if (r.t === "schema_migrations") continue
    const key = `${r.t}\u0000${r.i}`
    const g = grouped.get(key) ?? { nu: Number(r.nu), ty: String(r.ty), cols: [] }
    g.cols.push(String(r.c))
    grouped.set(key, g)
  }
  for (const [key, g] of grouped) {
    const [t, i] = key.split("\u0000") as [string, string]
    tableOf(t).indexes.push(`${i} ${g.nu ? "index" : "unique"}${g.ty === "BTREE" ? "" : ` ${g.ty.toLowerCase()}`} ${g.cols.join(",")}`)
  }
  for (const t of Object.values(out)) {
    t.columns.sort()
    t.indexes.sort()
  }
  return out
}
