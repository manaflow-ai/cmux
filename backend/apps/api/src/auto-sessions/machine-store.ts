import type { AutoMachine } from "./model.ts"

/**
 * Where an owner's Auto machines are kept, in their AutoSessionIndexDO's storage (index-do.ts):
 *
 * - `machine`: the one machine the owner named (`PUT /v1/auto-sessions/machine`). It is for every chat of theirs,
 *   whatever the chat's team, and it wins over any pick.
 * - `picks`: the machines the store picked itself (machine-pick.ts), one per team. A pick is answered only for a
 *   chat of its team, so a chat's events and folder never go to a machine of another team because some other chat
 *   needed a machine first, and a pick never changes a chat's team.
 */
const NAMED_TABLE = `CREATE TABLE IF NOT EXISTS machine (k INTEGER PRIMARY KEY CHECK (k = 1), team TEXT NOT NULL, machine TEXT NOT NULL)`
const PICKS_TABLE = `CREATE TABLE IF NOT EXISTS picks (team TEXT PRIMARY KEY, machine TEXT NOT NULL)`

export const hasColumn = (sql: SqlStorage, table: string, column: string): boolean =>
  sql.exec<{ name: string }>(`PRAGMA table_info(${table})`).toArray().some((c) => c.name === column)

/**
 * Makes the two tables. A store written while a pick was one per owner kept it in `machine`, marked `picked`: that
 * row is the pick of its team now, and `machine` holds only what the owner named.
 */
export const openMachineTables = (sql: SqlStorage): void => {
  sql.exec(NAMED_TABLE)
  sql.exec(PICKS_TABLE)
  if (!hasColumn(sql, "machine", "picked")) return
  sql.exec(`INSERT OR IGNORE INTO picks (team, machine) SELECT team, machine FROM machine WHERE picked = 1`)
  sql.exec(`DELETE FROM machine WHERE picked = 1`)
}

type Row = { team: string; machine: string }
const one = (rows: ReadonlyArray<Row>): AutoMachine | null => (rows[0] ? { team: rows[0].team, machine: rows[0].machine } : null)

/** The machine the owner named, or null. */
export const namedMachine = (sql: SqlStorage): AutoMachine | null => one(sql.exec<Row>(`SELECT team, machine FROM machine WHERE k = 1`).toArray())

/** The store's own pick for `team`, or null. */
export const pickedMachine = (sql: SqlStorage, team: string): AutoMachine | null => one(sql.exec<Row>(`SELECT team, machine FROM picks WHERE team = ?`, team).toArray())

/** The Auto machine of a chat of `team` as it is stored: the one the owner named, else that team's pick. */
export const storedMachine = (sql: SqlStorage, team: string): AutoMachine | null => namedMachine(sql) ?? pickedMachine(sql, team)

/** The owner named `m`. No pick is answered beside it, so none is kept. */
export const keepNamed = (sql: SqlStorage, m: AutoMachine): void => {
  sql.exec(`INSERT INTO machine (k, team, machine) VALUES (1, ?, ?) ON CONFLICT (k) DO UPDATE SET team = excluded.team, machine = excluded.machine`, m.team, m.machine)
  sql.exec(`DELETE FROM picks`)
}

export const keepPick = (sql: SqlStorage, m: AutoMachine): void =>
  void sql.exec(`INSERT INTO picks (team, machine) VALUES (?, ?) ON CONFLICT (team) DO UPDATE SET machine = excluded.machine`, m.team, m.machine)

export const dropPick = (sql: SqlStorage, team: string): void => void sql.exec(`DELETE FROM picks WHERE team = ?`, team)

export const sameMachine = (a: AutoMachine | null, b: AutoMachine | null): boolean => a?.team === b?.team && a?.machine === b?.machine
