import { hasColumn } from "./machine-store.ts"
import type { AssignmentKind, AutoRecord, MoveWish, Standby } from "./model.ts"

/**
 * The one row that is an Auto chat's record (model.ts AutoRecord), in its AutoSessionDO's SQLite storage. Beside
 * the record it keeps two things only the object reads: the version its owner's index last took, and when to try
 * that index write again.
 *
 * A column added after the first store was written is added to an older row by `openRecordTable`, which the
 * object runs when it starts: `move_wish` (the wish to move the chat, as JSON; null when there is none).
 */
type Row = {
  id: string
  owner: string
  team: string | null
  title: string
  harness: string
  auto: number
  keep_in_cloud: number
  holder: string
  epoch: number
  needs_run: number
  standby: string
  blocked: string | null
  assignment: string | null
  machine: string | null
  parked_from: string | null
  resumed_epoch: number
  last_seq: number
  snapshot: number
  snapshot_seq: number
  inbox: number
  inbox_acked: number
  repo_remote: string | null
  repo_branch: string | null
  event_bytes: number
  version: number
  created_at: number
  updated_at: number
  lease_expires_at: number
  owes_import: number
  move_wish: string | null
}

const TABLE = `CREATE TABLE IF NOT EXISTS session (k INTEGER PRIMARY KEY CHECK (k = 1), id TEXT NOT NULL, owner TEXT NOT NULL, team TEXT, title TEXT NOT NULL, harness TEXT NOT NULL, auto INTEGER NOT NULL, keep_in_cloud INTEGER NOT NULL, holder TEXT NOT NULL, epoch INTEGER NOT NULL, needs_run INTEGER NOT NULL, standby TEXT NOT NULL, blocked TEXT, assignment TEXT, machine TEXT, parked_from TEXT, resumed_epoch INTEGER NOT NULL DEFAULT 0, last_seq INTEGER NOT NULL, snapshot INTEGER NOT NULL, snapshot_seq INTEGER NOT NULL, inbox INTEGER NOT NULL, inbox_acked INTEGER NOT NULL, repo_remote TEXT, repo_branch TEXT, event_bytes INTEGER NOT NULL, version INTEGER NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, lease_expires_at INTEGER NOT NULL, owes_import INTEGER NOT NULL DEFAULT 0, indexed_version INTEGER NOT NULL DEFAULT 0, index_retry_at INTEGER NOT NULL DEFAULT 0, move_wish TEXT)`

const hasTable = (sql: SqlStorage): boolean => sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'session'`).toArray().length > 0

/**
 * A chat written before a column was added gets the column, empty. Run once when the chat's object starts, before
 * anything reads its row. A chat that was never made has no table, and still has none after this.
 */
export const openRecordTable = (sql: SqlStorage): void => {
  if (hasTable(sql) && !hasColumn(sql, "session", "move_wish")) sql.exec(`ALTER TABLE session ADD COLUMN move_wish TEXT`)
}

const standbyOf = (text: string): ReadonlyArray<Standby> => {
  const list = JSON.parse(text) as Array<[string, number]>
  return list.map(([holder, expiresAt]) => ({ holder, expiresAt }))
}

const recordOf = (r: Row): AutoRecord => ({
  id: r.id,
  owner: r.owner,
  team: r.team,
  title: r.title,
  harness: r.harness,
  auto: r.auto === 1,
  keepInCloud: r.keep_in_cloud === 1,
  holder: r.holder,
  epoch: r.epoch,
  needsRun: r.needs_run === 1,
  standby: standbyOf(r.standby),
  blocked: r.blocked === "no_machine" ? "no_machine" : null,
  assignment: r.assignment as AssignmentKind | null,
  machine: r.machine,
  parkedFrom: r.parked_from,
  resumedEpoch: r.resumed_epoch,
  lastSeq: r.last_seq,
  snapshot: r.snapshot,
  snapshotSeq: r.snapshot_seq,
  inbox: r.inbox,
  inboxAcked: r.inbox_acked,
  repo: r.repo_remote !== null && r.repo_branch !== null ? { remote: r.repo_remote, branch: r.repo_branch } : null,
  eventBytes: r.event_bytes,
  version: r.version,
  createdAt: r.created_at,
  updatedAt: r.updated_at,
  leaseExpiresAt: r.lease_expires_at,
  owesImport: r.owes_import === 1,
  move: r.move_wish === null ? null : (JSON.parse(r.move_wish) as MoveWish)
})

/** The tables exist only once a chat was made, so a read of an unknown id writes nothing. */
export const loadRecord = (sql: SqlStorage): AutoRecord | undefined => {
  if (!hasTable(sql)) return undefined
  const row = sql.exec(`SELECT * FROM session WHERE k = 1`).toArray()[0] as Row | undefined
  return row ? recordOf(row) : undefined
}

const values = (r: AutoRecord) => [
  r.team, r.title, r.harness, r.auto ? 1 : 0, r.keepInCloud ? 1 : 0, r.holder, r.epoch, r.needsRun ? 1 : 0, JSON.stringify(r.standby.map((s) => [s.holder, s.expiresAt])), r.blocked, r.assignment, r.machine, r.parkedFrom, r.resumedEpoch,
  r.lastSeq, r.snapshot, r.snapshotSeq, r.inbox, r.inboxAcked, r.repo?.remote ?? null, r.repo?.branch ?? null, r.eventBytes, r.version, r.updatedAt, r.leaseExpiresAt, r.owesImport ? 1 : 0,
  r.move === null ? null : JSON.stringify(r.move)
]

/** Makes the chat's tables (`also`: the events, chunks, snapshots and inbox tables) and its row. */
export const insertRecord = (sql: SqlStorage, r: AutoRecord, also: ReadonlyArray<string>): void => {
  sql.exec(TABLE)
  for (const table of also) sql.exec(table)
  sql.exec(
    `INSERT INTO session (k, id, owner, created_at, team, title, harness, auto, keep_in_cloud, holder, epoch, needs_run, standby, blocked, assignment, machine, parked_from, resumed_epoch, last_seq, snapshot, snapshot_seq, inbox, inbox_acked, repo_remote, repo_branch, event_bytes, version, updated_at, lease_expires_at, owes_import, move_wish) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    r.id, r.owner, r.createdAt, ...values(r)
  )
}

export const saveRecord = (sql: SqlStorage, r: AutoRecord): void => {
  sql.exec(
    `UPDATE session SET team = ?, title = ?, harness = ?, auto = ?, keep_in_cloud = ?, holder = ?, epoch = ?, needs_run = ?, standby = ?, blocked = ?, assignment = ?, machine = ?, parked_from = ?, resumed_epoch = ?, last_seq = ?, snapshot = ?, snapshot_seq = ?, inbox = ?, inbox_acked = ?, repo_remote = ?, repo_branch = ?, event_bytes = ?, version = ?, updated_at = ?, lease_expires_at = ?, owes_import = ?, move_wish = ? WHERE k = 1`,
    ...values(r)
  )
}

/** The version the owner's index has, and when its write is tried again (0: it is up to date). */
export const indexState = (sql: SqlStorage): { readonly indexed: number; readonly retryAt: number } => {
  const row = sql.exec<{ indexed_version: number; index_retry_at: number }>(`SELECT indexed_version, index_retry_at FROM session WHERE k = 1`).toArray()[0]
  return { indexed: row?.indexed_version ?? 0, retryAt: row?.index_retry_at ?? 0 }
}
export const armIndexRetry = (sql: SqlStorage, at: number): void => void sql.exec(`UPDATE session SET index_retry_at = ? WHERE k = 1`, at)
/** The index took `version`; the retry is dropped once that is the newest. */
export const markIndexed = (sql: SqlStorage, version: number): void =>
  void sql.exec(`UPDATE session SET indexed_version = max(indexed_version, ?), index_retry_at = CASE WHEN version <= max(indexed_version, ?) THEN 0 ELSE index_retry_at END WHERE k = 1`, version, version)
