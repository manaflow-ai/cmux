import type { SqlStore } from "@cmux/ownership"

/**
 * The team journal (plans/cmux-next/team-vm-plan.md 3b, S6): the zero-loss tier for writes the
 * team VM acknowledges. One contiguous log per stream; entries are seq ranges with opaque bytes
 * (a Tasks group commit, a mailbox message, a memory file version). An append returns after the
 * DO storage write is durable (the output gate holds the reply until then). Side tables, not the
 * OwnerEngine ledger: the entry key (stream, first_seq) is its own idempotency key.
 */

export const JOURNAL_STREAMS = ["tasks", "mail", "memory", "files"] as const
export type JournalStream = (typeof JOURNAL_STREAMS)[number]
/** One entry's payload limit (a Tasks group commit or one file version; larger files are chunked by the writer). */
export const MAX_ENTRY_BYTES = 1024 * 1024
/** One read returns whole entries up to about this many bytes (at least one entry). */
export const MAX_READ_BYTES = 4 * 1024 * 1024
/** Widest seq range of one entry (a group commit), and the highest seq; keeps every seq a safe integer forever. */
export const MAX_RANGE = 100_000
export const MAX_SEQ = 2 ** 50
/**
 * Journal bytes one team VM object may hold before compaction to R2 exists (follow-up slice S6b). Below
 * the DO's 10 GB limit so the VM record and leases in the same database keep working when it is full.
 */
export const MAX_JOURNAL_BYTES = 8 * 1024 ** 3

export interface JournalAck {
  readonly stream: JournalStream
  readonly first_seq: number
  readonly last_seq: number
  readonly epoch: number
  readonly high_water: number
  readonly replayed: boolean
}

export type JournalResult<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly code: string; readonly message: string; readonly details?: unknown }

const fail = (code: string, message: string, details?: unknown): { ok: false; code: string; message: string; details?: unknown } => ({ ok: false, code, message, ...(details === undefined ? {} : { details }) })

export const isStream = (s: unknown): s is JournalStream => typeof s === "string" && (JOURNAL_STREAMS as ReadonlyArray<string>).includes(s)

export const sha256Hex = async (bytes: Uint8Array) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)), (b) => b.toString(16).padStart(2, "0")).join("")

export const fromBase64 = (b64: string): Uint8Array | null => {
  try {
    return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))
  } catch {
    return null
  }
}

const toBase64 = (bytes: Uint8Array) => {
  let s = ""
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

export class TeamJournal {
  constructor(private readonly sql: SqlStore) {
    sql.exec(
      `CREATE TABLE IF NOT EXISTS journal_entry (stream TEXT NOT NULL, first_seq INTEGER NOT NULL, last_seq INTEGER NOT NULL, epoch INTEGER NOT NULL, sha256 TEXT NOT NULL, bytes BLOB NOT NULL, at INTEGER NOT NULL, PRIMARY KEY (stream, first_seq))`
    )
    sql.exec(`CREATE TABLE IF NOT EXISTS journal_head (stream TEXT PRIMARY KEY, high_water INTEGER NOT NULL, epoch INTEGER NOT NULL)`)
    sql.exec(`CREATE TABLE IF NOT EXISTS journal_usage (id INTEGER PRIMARY KEY CHECK (id = 1), bytes INTEGER NOT NULL)`)
    sql.exec(`INSERT OR IGNORE INTO journal_usage (id, bytes) VALUES (1, 0)`)
  }

  usedBytes(): number {
    return this.sql.exec<{ bytes: number }>(`SELECT bytes FROM journal_usage WHERE id = 1`)[0]?.bytes ?? 0
  }

  highWater(stream: JournalStream): { high_water: number; epoch: number } {
    return this.sql.exec<{ high_water: number; epoch: number }>(`SELECT high_water, epoch FROM journal_head WHERE stream = ?`, stream)[0] ?? { high_water: 0, epoch: 0 }
  }

  /**
   * Appends one range. Rules: `first_seq = high_water + 1` (contiguous); a replay of the same
   * (stream, first_seq) with the same last_seq and hash returns the stored ack; any other replay is
   * a conflict; an epoch lower than the stream's last epoch is refused (a stale VM after restore).
   * The caller checked that the writer is the current VM install and `epoch` is the record's epoch.
   */
  append(stream: JournalStream, epoch: number, first: number, last: number, bytes: Uint8Array, sha256: string, now: number): JournalResult<JournalAck> {
    if (!Number.isSafeInteger(first) || !Number.isSafeInteger(last) || first < 1 || last < first) return fail("validation.invalid", "need 1 <= first_seq <= last_seq")
    if (last - first + 1 > MAX_RANGE || last > MAX_SEQ) return fail("validation.invalid", `a range holds at most ${MAX_RANGE} seqs and ends at most at ${MAX_SEQ}`)
    if (bytes.length > MAX_ENTRY_BYTES) return fail("journal.too_large", `an entry holds at most ${MAX_ENTRY_BYTES} bytes`)
    return this.sql.transaction(() => {
      const head = this.highWater(stream)
      if (epoch < head.epoch) return fail("journal.stale_epoch", "a newer epoch already writes this stream", { epoch: head.epoch })
      const existing = this.sql.exec<{ last_seq: number; sha256: string; epoch: number }>(`SELECT last_seq, sha256, epoch FROM journal_entry WHERE stream = ? AND first_seq = ?`, stream, first)[0]
      if (existing) {
        if (existing.last_seq === last && existing.sha256 === sha256) return { ok: true, value: { stream, first_seq: first, last_seq: last, epoch: existing.epoch, high_water: head.high_water, replayed: true } }
        return fail("journal.conflict", "another entry already holds this first_seq", { high_water: head.high_water })
      }
      if (first !== head.high_water + 1) return fail("journal.gap", `first_seq must be ${head.high_water + 1}`, { high_water: head.high_water })
      const used = this.usedBytes()
      if (used + bytes.length > MAX_JOURNAL_BYTES) {
        console.error(JSON.stringify({ msg: "team journal full", stream, used }))
        return fail("journal.full", "the team journal is full until compaction runs", { used })
      }
      this.sql.exec(`UPDATE journal_usage SET bytes = bytes + ? WHERE id = 1`, bytes.length)
      this.sql.exec(`INSERT INTO journal_entry (stream, first_seq, last_seq, epoch, sha256, bytes, at) VALUES (?, ?, ?, ?, ?, ?, ?)`, stream, first, last, epoch, sha256, bytes.slice().buffer, now)
      this.sql.exec(
        `INSERT INTO journal_head (stream, high_water, epoch) VALUES (?, ?, ?) ON CONFLICT (stream) DO UPDATE SET high_water = excluded.high_water, epoch = excluded.epoch`,
        stream,
        last,
        epoch
      )
      return { ok: true, value: { stream, first_seq: first, last_seq: last, epoch, high_water: last, replayed: false } }
    })
  }

  /**
   * Whole entries whose range ends at or after `from_seq`, in order, up to about MAX_READ_BYTES.
   * Sizes are read first without the blobs, so one call never loads more than the cut-off into memory.
   */
  read(stream: JournalStream, fromSeq: number): { entries: Array<{ first_seq: number; last_seq: number; epoch: number; sha256: string; bytes: string }>; high_water: number; more: boolean } {
    const from = Math.max(1, Math.floor(fromSeq))
    const sizes = this.sql.exec<{ first_seq: number; size: number }>(
      `SELECT first_seq, length(bytes) AS size FROM journal_entry WHERE stream = ? AND last_seq >= ? ORDER BY first_seq LIMIT 1000`,
      stream,
      from
    )
    let take = 0
    let total = 0
    for (const r of sizes) {
      if (take > 0 && total + r.size > MAX_READ_BYTES) break
      total += r.size
      take++
    }
    const more = take < sizes.length || sizes.length === 1000
    const entries: Array<{ first_seq: number; last_seq: number; epoch: number; sha256: string; bytes: string }> = []
    if (take > 0) {
      const lastFirst = sizes[take - 1]!.first_seq
      const rows = this.sql.exec<{ first_seq: number; last_seq: number; epoch: number; sha256: string; bytes: ArrayBuffer | Uint8Array }>(
        `SELECT first_seq, last_seq, epoch, sha256, bytes FROM journal_entry WHERE stream = ? AND last_seq >= ? AND first_seq <= ? ORDER BY first_seq`,
        stream,
        from,
        lastFirst
      )
      for (const r of rows) entries.push({ first_seq: r.first_seq, last_seq: r.last_seq, epoch: r.epoch, sha256: r.sha256, bytes: toBase64(r.bytes instanceof Uint8Array ? r.bytes : new Uint8Array(r.bytes)) })
    }
    return { entries, high_water: this.highWater(stream).high_water, more }
  }
}
