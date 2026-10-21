import type { Classified } from "./hand-classify.ts"

/**
 * The verdict log of a mac hand (one HandDO's SQLite): every classifier verdict with its request
 * (action, caller, the request's shape), so the owner can audit what ran, what asked and why.
 */
const KEEP = 10_000

export const createVerdictTable = (sql: SqlStorage) =>
  sql.exec(`CREATE TABLE IF NOT EXISTS hand_verdict (seq INTEGER PRIMARY KEY AUTOINCREMENT, at INTEGER NOT NULL, req TEXT NOT NULL, action TEXT NOT NULL, who TEXT NOT NULL, verdict TEXT NOT NULL, reason TEXT NOT NULL, model TEXT NOT NULL, ms INTEGER NOT NULL, summary TEXT NOT NULL)`)

/** `summary`: the request's shape for the log (paths, argv, the head of any text), never whole file bodies. */
export const recordVerdict = (sql: SqlStorage, req: string, action: string, who: string, v: Classified, summary: string) => {
  sql.exec(`INSERT INTO hand_verdict (at, req, action, who, verdict, reason, model, ms, summary) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`, Date.now(), req, action, who, v.verdict, v.reason, v.model, v.ms, summary)
  sql.exec(`DELETE FROM hand_verdict WHERE seq <= (SELECT MAX(seq) FROM hand_verdict) - ?`, KEEP)
}

export const listVerdicts = (sql: SqlStorage, limit: number): Array<Record<string, unknown>> =>
  sql.exec(`SELECT seq, at, req, action, who, verdict, reason, model, ms, summary FROM hand_verdict ORDER BY seq DESC LIMIT ?`, Math.min(Math.max(limit, 1), 1000)).toArray()
