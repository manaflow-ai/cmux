import { envForObject } from "../build-space.ts"
import { DurableObject } from "cloudflare:workers"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env, RawEnv } from "../env.ts"
import { wakeCloud } from "../mux-machine-wake.ts"
import { dueStarts, hasStart, nextStartAt, openStart, STARTS_TABLE, stepStart } from "./machine-start.ts"
import { MAX_WAIT_MS, type AssignmentKind, type AutoIndexEntry, type AutoMachine, type AutoSessionView } from "./model.ts"

export type AutoListCursor = { readonly createdAt: number; readonly id: string }
export type AutoAssignment = { readonly kind: AssignmentKind; readonly session: AutoSessionView }
type Row = { id: string; view: string; assign_kind: string | null; epoch: number; version: number }
/** How soon the alarm looks again after a start step could not run at all. */
const STEP_RETRY_MS = 5_000

/** Whether `owner` may use a Cloud machine of `team`: their personal team, or a shared team their role has resources in. */
export const mayUseTeam = async (env: Env, owner: string, team: string): Promise<boolean> =>
  team === personalTeamIdFor(owner) || roleHas((await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).memberRole(team, owner)) ?? undefined, "team.resources")

/**
 * AutoSessionIndexDO: one per owner (name = the owner's user id), the AccountIndexDO and HandoffIndexDO pattern.
 * It owns no chat: each AutoSessionDO writes its row here after its own change (a late, older write changes
 * nothing) and retries a lost write from its alarm. What it keeps:
 *
 * - The owner's Auto chats, newest first, for `GET /v1/auto-sessions`.
 * - The owner's Auto machine (`GET` and `PUT /v1/auto-sessions/machine`).
 * - The assignments a machine has not acked. A chat's row names the machine it was given to and what for, under an
 *   index on the machine, so a machine's `GET /v1/auto-sessions/assignments` reads its own rows and never scans
 *   the owner's chats. The wait is held here: a row that gains an assignment wakes it.
 * - One start per machine with an assignment waiting (machine-start.ts), stepped by this object's alarm.
 */
export class AutoSessionIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) {
    super(ctx, envForObject(ctx, raw))
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, view TEXT NOT NULL, auto INTEGER NOT NULL, blocked INTEGER NOT NULL DEFAULT 0, assign_kind TEXT, assign_machine TEXT, epoch INTEGER NOT NULL, created_at INTEGER NOT NULL, version INTEGER NOT NULL)`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_newest ON sessions (created_at DESC, id DESC)`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_assigned ON sessions (assign_machine) WHERE assign_kind IS NOT NULL`)
    sql.exec(`CREATE TABLE IF NOT EXISTS machine (k INTEGER PRIMARY KEY CHECK (k = 1), team TEXT NOT NULL, machine TEXT NOT NULL)`)
    sql.exec(STARTS_TABLE)
  }

  private readonly waiters = new Set<() => void>()
  /** Alarm runs in order, one at a time; a test waits on it. */
  alarmIdle: Promise<void> = Promise.resolve()

  private get sql(): SqlStorage {
    return this.ctx.storage.sql
  }

  private async arm(): Promise<void> {
    const at = nextStartAt(this.sql)
    if (at === null) return this.ctx.storage.deleteAlarm()
    await this.ctx.storage.setAlarm(at)
  }

  /** A chat's row after its change. A new assignment opens its machine's start and wakes the machine's wait. */
  async put(e: AutoIndexEntry): Promise<void> {
    const old = this.sql.exec<Row>(`SELECT id, view, assign_kind, epoch, version FROM sessions WHERE id = ?`, e.id).toArray()[0]
    if (old && old.version >= e.view.version) return
    this.sql.exec(
      `INSERT INTO sessions (id, view, auto, blocked, assign_kind, assign_machine, epoch, created_at, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET view = excluded.view, auto = excluded.auto, blocked = excluded.blocked, assign_kind = excluded.assign_kind, assign_machine = excluded.assign_machine, epoch = excluded.epoch, version = excluded.version`,
      e.id, JSON.stringify(e.view), e.view.auto ? 1 : 0, e.view.blocked === "no_machine" ? 1 : 0, e.assignment?.kind ?? null, e.assignment?.machine ?? null, e.view.epoch, e.view.createdAt, e.view.version
    )
    if (!e.assignment) return
    // Open the machine's start for an assignment it has not seen, or when none is open (an earlier one ended).
    const fresh = !old || old.assign_kind !== e.assignment.kind || old.epoch !== e.view.epoch
    if (fresh || !hasStart(this.sql, e.assignment.machine)) {
      openStart(this.sql, { machine: e.assignment.machine, team: e.assignment.team, owner: e.owner }, Date.now())
      await this.arm()
    }
    for (const wake of [...this.waiters]) wake()
  }

  /** Newest first; `before` is the last row of the previous page. Closed chats are not listed. */
  async list(limit: number, before?: AutoListCursor): Promise<{ readonly sessions: ReadonlyArray<AutoSessionView>; readonly next: AutoListCursor | null }> {
    const rows = (before
      ? this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 AND (created_at < ? OR (created_at = ? AND id < ?)) ORDER BY created_at DESC, id DESC LIMIT ?`, before.createdAt, before.createdAt, before.id, limit + 1)
      : this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 ORDER BY created_at DESC, id DESC LIMIT ?`, limit + 1)
    ).toArray()
    const page = rows.slice(0, limit)
    const last = page.at(-1)
    return { sessions: page.map((r) => JSON.parse(r.view) as AutoSessionView), next: rows.length > limit && last ? { createdAt: last.created_at, id: last.id } : null }
  }

  async machine(): Promise<AutoMachine | null> {
    const row = this.sql.exec<{ team: string; machine: string }>(`SELECT team, machine FROM machine WHERE k = 1`).toArray()[0]
    return row ? { team: row.team, machine: row.machine } : null
  }

  /** Sets the owner's Auto machine; answers the chats that were waiting for one, for the caller to send to it. */
  async setMachine(m: AutoMachine): Promise<{ readonly blocked: ReadonlyArray<string> }> {
    this.sql.exec(`INSERT INTO machine (k, team, machine) VALUES (1, ?, ?) ON CONFLICT (k) DO UPDATE SET team = excluded.team, machine = excluded.machine`, m.team, m.machine)
    return { blocked: this.sql.exec<{ id: string }>(`SELECT id FROM sessions WHERE auto = 1 AND blocked = 1 ORDER BY created_at LIMIT 100`).toArray().map((r) => r.id) }
  }

  private assigned(machine: string): ReadonlyArray<AutoAssignment> {
    return this.sql
      .exec<{ view: string; assign_kind: string }>(`SELECT view, assign_kind FROM sessions WHERE assign_machine = ? AND assign_kind IS NOT NULL ORDER BY created_at LIMIT 100`, machine)
      .toArray()
      .map((r) => ({ kind: r.assign_kind as AssignmentKind, session: JSON.parse(r.view) as AutoSessionView }))
  }

  /** `GET /v1/auto-sessions/assignments`: what `machine` has not acked, held until there is one or the deadline (at most MAX_WAIT_MS). */
  async assignments(machine: string, waitMs: number): Promise<ReadonlyArray<AutoAssignment>> {
    const deadline = Date.now() + Math.max(0, Math.min(waitMs, MAX_WAIT_MS))
    for (;;) {
      const found = this.assigned(machine)
      if (found.length > 0 || Date.now() >= deadline) return found
      await new Promise<void>((resolve) => {
        const done = () => (clearTimeout(timer), this.waiters.delete(done), resolve())
        const timer = setTimeout(done, Math.max(0, deadline - Date.now()))
        this.waiters.add(done)
      })
    }
  }

  override alarm(): Promise<void> {
    return (this.alarmIdle = this.alarmIdle.then(() => this.due()))
  }

  /** The alarm: one look at each machine whose start is due. Never throws: a start that fails backs off by itself. */
  private async due(): Promise<void> {
    try {
      for (const row of dueStarts(this.sql, Date.now())) {
        const pending = this.sql.exec(`SELECT 1 FROM sessions WHERE assign_machine = ? AND assign_kind IS NOT NULL LIMIT 1`, row.machine).toArray().length
        await stepStart(this.sql, wakeCloud(this.env), (owner, team) => mayUseTeam(this.env, owner, team), row, pending, Date.now())
      }
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.start_step_failed", error: String(e).slice(0, 200) }))
      // Whatever was due waits a little, so a step that cannot run does not bring the alarm straight back.
      this.sql.exec(`UPDATE starts SET next_at = ? WHERE next_at <= ?`, Date.now() + STEP_RETRY_MS, Date.now())
    }
    await this.arm().catch(() => undefined)
  }
}
