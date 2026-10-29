import { DurableObject } from "cloudflare:workers"
import type { Env } from "../env.ts"

/**
 * Cloud work mode's hand-off store (leo-workspace design/cloud-work-mode.md). A hand-off is an
 * agent session the owner sent to a cloud machine; the transcript stays the session's, so the
 * store keeps only who owns it, which session, which machine and size, and its current turn: the
 * turn's number, status and short final summary. No attempts, no event log, no transcript copy.
 *
 * One hand-off per session, a turn generation inside it (cmuxterm-hq#4706): a follow-up in the same
 * cloud chat is a new turn of the same hand-off, never a new hand-off. Only the owner opens a turn
 * (`beginTurn`); a machine report names its turn, so a late report of an older turn changes nothing.
 * done, failed and cancelled end a turn; only `close` ends the hand-off.
 */
export const HANDOFF_STATUSES = ["starting", "running", "needs-you", "done", "failed", "cancelled"] as const
export type HandoffStatus = (typeof HANDOFF_STATUSES)[number]
/** What the machine may report; `starting` is only a turn's first state and `cancelled` only the owner's. */
export const MACHINE_STATUSES: ReadonlySet<string> = new Set(["running", "needs-you", "done", "failed"])
/** Statuses that end a turn (not the hand-off). */
export const FINISHED: ReadonlySet<string> = new Set(["done", "failed", "cancelled"])
export type HandoffState = "open" | "closed"
export const SUMMARY_MAX_CHARS = 2_000
/** The longest one wait holds a request. */
export const MAX_WAIT_MS = 25_000

/** The machine size the hand-off was given; the size pick (auto-sizing) and its reason are plain text. */
export type HandoffSize = { readonly vcpus: number | null; readonly memoryGb: number | null; readonly pick: string | null; readonly reason: string | null }
export type HandoffInit = { readonly id: string; readonly owner: string; readonly requestDigest: string; readonly sessionId: string; readonly machine: string; readonly size: HandoffSize }
export type HandoffView = {
  readonly id: string
  readonly sessionId: string
  readonly machine: string
  readonly size: HandoffSize
  /** The hand-off's current turn: 1 at create, one more each time the owner begins a turn. */
  readonly turn: number
  /** `closed` once the owner closed it; nothing changes it after that. */
  readonly state: HandoffState
  /** The current turn's status. */
  readonly status: HandoffStatus
  readonly summary: string | null
  /** Counts every change; a wait passes the last one it saw. */
  readonly version: number
  readonly createdAt: string
  readonly updatedAt: string
  /** When the status last changed. */
  readonly statusAt: string
  /** When the current turn first ran and when it ended. */
  readonly startedAt: string | null
  readonly finishedAt: string | null
}
/** The owner's create answer: the view, and the hand-off's machine token (the machine's credential when it has no VM install). */
export type HandoffCreated = { readonly handoff: HandoffView; readonly machineToken: string }
/** The machine side: the hand-off's machine token, or a VM install (its owner and bound machine, as the Worker resolved them). */
export type MachineCredential = { readonly token: string } | { readonly owner: string; readonly machine: string }
export type HandoffFail =
  | "handoff.not_found"
  | "handoff.conflict"
  | "handoff.closed"
  | "handoff.stale"
  | "handoff.turn_finished"
  | "handoff.turn_out_of_order"
  | "handoff.turn_conflict"
  | "handoff.turn_running"
export type HandoffResult<T> = { readonly ok: true; readonly value: T } | { readonly ok: false; readonly code: HandoffFail; readonly message: string; readonly handoff?: HandoffView }
export type HandoffIndexEntry = { readonly id: string; readonly sessionId: string; readonly turn: number; readonly state: HandoffState; readonly status: HandoffStatus; readonly summary: string | null; readonly createdAt: number; readonly updatedAt: number; readonly version: number }

type Row = {
  id: string
  owner: string
  request_digest: string
  session_id: string
  machine: string
  vcpus: number | null
  memory_gb: number | null
  size_pick: string | null
  size_reason: string | null
  machine_token: string
  turn: number
  state: string
  status: string
  summary: string | null
  version: number
  indexed_version: number
  created_at: number
  updated_at: number
  status_at: number
  started_at: number | null
  finished_at: number | null
}

const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString())
const ok = <T>(value: T): HandoffResult<T> => ({ ok: true, value })
const notFound: HandoffResult<never> = { ok: false, code: "handoff.not_found", message: "hand-off not found" }
const refuse = (code: HandoffFail, message: string, r: Row): HandoffResult<never> => ({ ok: false, code, message, handoff: view(r) })
/** How soon a hand-off retries a failed write to its owner's index. */
const INDEX_RETRY_MS = 30_000

const view = (r: Row): HandoffView => ({
  id: r.id,
  sessionId: r.session_id,
  machine: r.machine,
  size: { vcpus: r.vcpus, memoryGb: r.memory_gb, pick: r.size_pick, reason: r.size_reason },
  turn: r.turn,
  state: r.state as HandoffState,
  status: r.status as HandoffStatus,
  summary: r.summary,
  version: r.version,
  createdAt: new Date(r.created_at).toISOString(),
  updatedAt: new Date(r.updated_at).toISOString(),
  statusAt: new Date(r.status_at).toISOString(),
  startedAt: iso(r.started_at),
  finishedAt: iso(r.finished_at)
})

/**
 * HandoffDO: one per hand-off (name = the hand-off id). Its one row is the hand-off; this object is
 * its only writer. Tables exist only once `init` ran, so a read of an unknown id writes nothing.
 * After each change it wakes its waits and writes the owner's HandoffIndexDO row (by version); the
 * change arms an alarm in the same write, cleared once the index has it, so no write is lost.
 * A wait ends on the next change or at its deadline (at most
 * MAX_WAIT_MS); no timer outlives its request.
 */
export class HandoffDO extends DurableObject<Env> {
  private readonly waiters = new Set<() => void>()

  private migrated = false
  private row(): Row | undefined {
    const sql = this.ctx.storage.sql
    const exists = sql.exec(`SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'handoff'`).toArray().length > 0
    if (!exists) return undefined
    // Rows from before turns (staging only) get turn 1, open.
    if (!this.migrated) {
      const columns = new Set(sql.exec(`SELECT name FROM pragma_table_info('handoff')`).toArray().map((c) => String(c.name)))
      if (!columns.has("turn")) sql.exec(`ALTER TABLE handoff ADD COLUMN turn INTEGER NOT NULL DEFAULT 1`)
      if (!columns.has("state")) sql.exec(`ALTER TABLE handoff ADD COLUMN state TEXT NOT NULL DEFAULT 'open'`)
      this.migrated = true
    }
    return sql.exec(`SELECT * FROM handoff WHERE k = 1`).toArray()[0] as Row | undefined
  }
  private owned(owner: string): Row | undefined {
    const r = this.row()
    return r && r.owner === owner ? r : undefined
  }

  /**
   * After every change. The change itself armed the index retry (`commit`), so a reset before the
   * index write still reaches the index; the alarm is cleared only once the newest version is there.
   */
  private async changed(): Promise<void> {
    for (const wake of [...this.waiters]) wake()
    const r = this.row()!
    if (r.indexed_version >= r.version) return
    try {
      const ns = this.env.HANDOFF_INDEX_DO!
      await ns.get(ns.idFromName(r.owner)).put({ id: r.id, sessionId: r.session_id, turn: r.turn, state: r.state as HandoffState, status: r.status as HandoffStatus, summary: r.summary, createdAt: r.created_at, updatedAt: r.updated_at, version: r.version })
      this.ctx.storage.sql.exec(`UPDATE handoff SET indexed_version = max(indexed_version, ?) WHERE k = 1`, r.version)
      const now = this.row()!
      if (now.indexed_version >= now.version) await this.ctx.storage.deleteAlarm()
    } catch (e) {
      console.warn(JSON.stringify({ msg: "handoffs.index_put_failed", error: String(e).slice(0, 200) }))
      await this.ctx.storage.setAlarm(Date.now() + INDEX_RETRY_MS)
    }
  }

  /**
   * One decision and its write, in one transaction: `decide` reads the row there and either writes
   * (and returns null) or returns the answer without writing. So no check can go stale before its
   * write, whatever awaits a caller adds later. A write arms the index retry alarm in the same
   * write (no await between them), then wakes waits and writes the index; a refusal or a no-op does neither.
   */
  private async commit<T>(decide: (r: Row) => HandoffResult<T> | null, wrote: () => HandoffResult<T>): Promise<HandoffResult<T>> {
    const answer = this.ctx.storage.transactionSync(() => decide(this.row()!))
    if (answer !== null) return answer
    // Called before any await, so the alarm commits with the change's rows.
    await this.ctx.storage.setAlarm(Date.now() + INDEX_RETRY_MS)
    await this.changed()
    return wrote()
  }

  override async alarm(): Promise<void> {
    if (this.row()) await this.changed()
  }

  /** A report that ends the turn sets the summary to its own (none clears it), so a retry of it is an exact repeat; otherwise a missing summary keeps the last one. */
  private set(now: number, status: HandoffStatus | null, summary: string | null, replaceSummary = false) {
    const r = this.row()!
    const moved = status !== null && status !== r.status
    this.ctx.storage.sql.exec(
      `UPDATE handoff SET status = ?, summary = CASE WHEN ? THEN ? ELSE coalesce(?, summary) END, status_at = ?, started_at = CASE WHEN ? = 'running' THEN coalesce(started_at, ?) ELSE started_at END, finished_at = CASE WHEN ? THEN ? ELSE finished_at END, updated_at = ?, version = version + 1 WHERE k = 1`,
      status ?? r.status, replaceSummary ? 1 : 0, summary, summary, moved ? now : r.status_at, status ?? "", now, status !== null && FINISHED.has(status) ? 1 : 0, now, now
    )
  }

  /** Creates the session's hand-off; the same request again answers it, another request for the session conflicts. */
  async init(input: HandoffInit): Promise<HandoffResult<HandoffCreated>> {
    const existing = this.row()
    if (existing) {
      if (existing.owner !== input.owner || existing.request_digest !== input.requestDigest) return { ok: false, code: "handoff.conflict", message: "the session was already handed off with a different machine or size" }
      return ok({ handoff: view(existing), machineToken: existing.machine_token })
    }
    const now = Date.now()
    const token = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("")
    this.ctx.storage.transactionSync(() => {
      this.ctx.storage.sql.exec(`CREATE TABLE IF NOT EXISTS handoff (k INTEGER PRIMARY KEY CHECK (k = 1), id TEXT NOT NULL, owner TEXT NOT NULL, request_digest TEXT NOT NULL, session_id TEXT NOT NULL, machine TEXT NOT NULL, vcpus REAL, memory_gb REAL, size_pick TEXT, size_reason TEXT, machine_token TEXT NOT NULL, turn INTEGER NOT NULL DEFAULT 1, state TEXT NOT NULL DEFAULT 'open', status TEXT NOT NULL, summary TEXT, version INTEGER NOT NULL, indexed_version INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, status_at INTEGER NOT NULL, started_at INTEGER, finished_at INTEGER)`)
      this.ctx.storage.sql.exec(
        `INSERT INTO handoff (k, id, owner, request_digest, session_id, machine, vcpus, memory_gb, size_pick, size_reason, machine_token, status, version, created_at, updated_at, status_at) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'starting', 1, ?, ?, ?)`,
        input.id, input.owner, input.requestDigest, input.sessionId, input.machine, input.size.vcpus, input.size.memoryGb, input.size.pick, input.size.reason, token, now, now, now
      )
    })
    await this.ctx.storage.setAlarm(Date.now() + INDEX_RETRY_MS)
    await this.changed()
    return ok({ handoff: view(this.row()!), machineToken: token })
  }

  async get(owner: string): Promise<HandoffResult<HandoffView>> {
    const r = this.owned(owner)
    return r ? ok(view(r)) : notFound
  }

  /**
   * The hand-off once its version is past `after` (a change since the caller last looked), once it is
   * closed, or at the deadline. A turn that ended does not end the wait: a follow-up opens the next turn.
   */
  async wait(owner: string, after: number, waitMs: number): Promise<HandoffResult<HandoffView>> {
    const deadline = Date.now() + Math.max(0, Math.min(waitMs, MAX_WAIT_MS))
    for (;;) {
      const r = this.owned(owner)
      if (!r) return notFound
      if (r.version > after || r.state === "closed" || Date.now() >= deadline) return ok(view(r))
      await new Promise<void>((resolve) => {
        const done = () => (clearTimeout(timer), this.waiters.delete(done), resolve())
        const timer = setTimeout(done, Math.max(0, deadline - Date.now()))
        this.waiters.add(done)
      })
    }
  }

  private current = (): HandoffResult<HandoffView> => ok(view(this.row()!))

  /** The owner stops the current turn (Stop): a turn not yet ended becomes cancelled; the machine learns on its next report. */
  async cancel(owner: string): Promise<HandoffResult<HandoffView>> {
    if (!this.owned(owner)) return notFound
    return this.commit((r) => {
      if (r.state === "closed" || FINISHED.has(r.status)) return ok(view(r))
      this.set(Date.now(), "cancelled", null)
      return null
    }, this.current)
  }

  /**
   * The owner opens turn `after + 1` (a follow-up to a turn that ended). `after` is the turn the
   * caller last saw, so a repeat answers the turn it already opened and a stale caller is refused.
   */
  async beginTurn(owner: string, after: number): Promise<HandoffResult<HandoffView>> {
    if (!this.owned(owner)) return notFound
    return this.commit((r) => {
      if (r.state === "closed") return refuse("handoff.closed", "the hand-off is closed", r)
      if (r.turn === after + 1) return ok(view(r))
      if (r.turn !== after) return refuse("handoff.turn_conflict", `the current turn is ${r.turn}, not ${after}`, r)
      if (!FINISHED.has(r.status)) return refuse("handoff.turn_running", `turn ${r.turn} is still ${r.status}; send to it instead`, r)
      const now = Date.now()
      this.ctx.storage.sql.exec(
        `UPDATE handoff SET turn = turn + 1, status = 'starting', summary = NULL, status_at = ?, started_at = NULL, finished_at = NULL, updated_at = ?, version = version + 1 WHERE k = 1`,
        now, now
      )
      return null
    }, this.current)
  }

  /** The owner ends the hand-off: the one terminal change. A turn still going is cancelled with it. */
  async close(owner: string): Promise<HandoffResult<HandoffView>> {
    if (!this.owned(owner)) return notFound
    return this.commit((r) => {
      if (r.state === "closed") return ok(view(r))
      const now = Date.now()
      if (!FINISHED.has(r.status)) this.set(now, "cancelled", null)
      this.ctx.storage.sql.exec(`UPDATE handoff SET state = 'closed', updated_at = ?, version = version + 1 WHERE k = 1`, now)
      return null
    }, this.current)
  }

  /** Whether `cred` speaks for this hand-off's machine: its machine token, or a VM install of the owner bound to its machine. */
  private machineMay(r: Row, cred: MachineCredential): boolean {
    if ("token" in cred) {
      const a = new TextEncoder().encode(cred.token)
      const b = new TextEncoder().encode(r.machine_token)
      return a.byteLength === b.byteLength && crypto.subtle.timingSafeEqual(a, b)
    }
    return cred.owner === r.owner && cred.machine === r.machine
  }

  /**
   * The machine's report on `turn`: a status and, when the turn ends, its summary. Only the current
   * turn changes: an older turn is stale, a later one was never opened (only the owner opens turns),
   * and an ended turn refuses more, except an exact repeat of its final report (a retry), which
   * answers it unchanged. A report that changes nothing (the same status, no new summary) moves no
   * version, so no wait wakes for it. A refusal carries the hand-off, so the machine learns the current
   * turn from it (a machine starts at turn 1 and retries on the turn a `handoff.stale` names).
   */
  async report(cred: MachineCredential, turn: number, status: string, summary: string | null): Promise<HandoffResult<HandoffView>> {
    const found = this.row()
    // Anyone but its machine learns nothing, not even that it exists.
    if (!found || !this.machineMay(found, cred)) return notFound
    const text = summary === null ? null : summary.slice(0, SUMMARY_MAX_CHARS)
    return this.commit((r) => {
      if (r.state === "closed") return refuse("handoff.closed", "the hand-off is closed", r)
      if (turn < r.turn) return refuse("handoff.stale", `turn ${turn} is over; the current turn is ${r.turn}`, r)
      if (turn > r.turn) return refuse("handoff.turn_out_of_order", `turn ${turn} has not begun; the current turn is ${r.turn}`, r)
      if (FINISHED.has(r.status)) {
        return status === r.status && text === r.summary ? ok(view(r)) : refuse("handoff.turn_finished", `turn ${r.turn} is already ${r.status}`, r)
      }
      if (status === r.status && (text === null || text === r.summary)) return ok(view(r))
      this.set(Date.now(), status as HandoffStatus, text, FINISHED.has(status))
      return null
    }, this.current)
  }
}
