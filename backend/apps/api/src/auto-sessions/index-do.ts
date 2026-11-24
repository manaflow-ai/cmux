import { envForObject } from "../build-space.ts"
import { DurableObject } from "cloudflare:workers"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env, RawEnv } from "../env.ts"
import { GIVE_UP_MS, wakeCloud } from "../mux-machine-wake.ts"
import { closeLook, dueLook, findMachine, LOOK_MIN_MS, LOOK_TABLE, missLook, nextLookAt, openLook, PICK_CHECK_MS } from "./machine-pick.ts"
import { dueStarts, hasStart, nextStartAt, openStart, STARTS_TABLE, stepStart } from "./machine-start.ts"
import { MAX_WAIT_MS, type AssignmentKind, type AutoIndexEntry, type AutoMachine, type AutoSessionView } from "./model.ts"

export type AutoListCursor = { readonly createdAt: number; readonly id: string }
export type AutoAssignment = { readonly kind: AssignmentKind; readonly session: AutoSessionView }
type Row = { id: string; view: string; assign_kind: string | null; epoch: number; version: number }
/** The owner's Auto machine as stored. `picked`: the store chose it (machine-pick.ts); the owner did not name it. */
type Stored = AutoMachine & { readonly picked: boolean }
const plain = (m: Stored | null): AutoMachine | null => (m ? { team: m.team, machine: m.machine } : null)
/** How soon the alarm looks again after a start step could not run at all. */
const STEP_RETRY_MS = 5_000
/** The teams one look for a machine reads, at most. */
const MAX_LOOK_TEAMS = 3

/** Whether `owner` may use a Cloud machine of `team`: their personal team, or a shared team their role has resources in. */
export const mayUseTeam = async (env: Env, owner: string, team: string): Promise<boolean> =>
  team === personalTeamIdFor(owner) || roleHas((await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).memberRole(team, owner)) ?? undefined, "team.resources")

/**
 * AutoSessionIndexDO: one per owner (name = the owner's user id), the AccountIndexDO and HandoffIndexDO pattern.
 * It owns no chat: each AutoSessionDO writes its row here after its own change (a late, older write changes
 * nothing) and retries a lost write from its alarm. What it keeps:
 *
 * - The owner's Auto chats, newest first, for `GET /v1/auto-sessions`.
 * - The owner's Auto machine: the one they named (`PUT /v1/auto-sessions/machine`), else one of their own Cloud
 *   machines that this object picks and keeps (`autoMachine`, the one lookup every reader calls).
 * - The assignments a machine has not acked. A chat's row names the machine it was given to and what for, under an
 *   index on the machine, so a machine's `GET /v1/auto-sessions/assignments` reads its own rows and never scans
 *   the owner's chats. The wait is held here: a row that gains an assignment wakes it.
 * - One start per machine with an assignment waiting (machine-start.ts), and one look for a machine while a chat
 *   waits for one (machine-pick.ts), both stepped by this object's alarm.
 */
export class AutoSessionIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) {
    super(ctx, envForObject(ctx, raw))
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, view TEXT NOT NULL, auto INTEGER NOT NULL, blocked INTEGER NOT NULL DEFAULT 0, assign_kind TEXT, assign_machine TEXT, epoch INTEGER NOT NULL, created_at INTEGER NOT NULL, version INTEGER NOT NULL)`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_newest ON sessions (created_at DESC, id DESC)`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_assigned ON sessions (assign_machine) WHERE assign_kind IS NOT NULL`)
    sql.exec(`CREATE TABLE IF NOT EXISTS machine (k INTEGER PRIMARY KEY CHECK (k = 1), team TEXT NOT NULL, machine TEXT NOT NULL, picked INTEGER NOT NULL DEFAULT 0)`)
    // An object made before the store picked machines has the table without `picked`: what it holds was named by the owner.
    if (!sql.exec<{ name: string }>(`PRAGMA table_info(machine)`).toArray().some((c) => c.name === "picked")) sql.exec(`ALTER TABLE machine ADD COLUMN picked INTEGER NOT NULL DEFAULT 0`)
    sql.exec(STARTS_TABLE)
    sql.exec(LOOK_TABLE)
  }

  private readonly waiters = new Set<() => void>()
  /** Per team: when its machines were last read, and the read that is under way (a second caller joins it). */
  private readonly looked = new Map<string, number>()
  private readonly looking = new Map<string, Promise<AutoMachine | null>>()
  /** Alarm runs in order, one at a time; a test waits on it. */
  alarmIdle: Promise<void> = Promise.resolve()

  private get sql(): SqlStorage {
    return this.ctx.storage.sql
  }

  private async arm(): Promise<void> {
    const times = [nextStartAt(this.sql), nextLookAt(this.sql)].filter((t): t is number => t !== null)
    if (times.length === 0) return this.ctx.storage.deleteAlarm()
    await this.ctx.storage.setAlarm(Math.min(...times))
  }

  /**
   * A chat's row after its change. A new assignment opens its machine's start and wakes the machine's wait. To a
   * chat that waits for an Auto machine it answers the one the owner has, if any: the chat was parked while the
   * machine was being set, and goes to it now. With none, the alarm starts looking for one.
   */
  async put(e: AutoIndexEntry): Promise<AutoMachine | null> {
    const old = this.sql.exec<Row>(`SELECT id, view, assign_kind, epoch, version FROM sessions WHERE id = ?`, e.id).toArray()[0]
    if (old && old.version >= e.view.version) return null
    this.sql.exec(
      `INSERT INTO sessions (id, view, auto, blocked, assign_kind, assign_machine, epoch, created_at, version) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET view = excluded.view, auto = excluded.auto, blocked = excluded.blocked, assign_kind = excluded.assign_kind, assign_machine = excluded.assign_machine, epoch = excluded.epoch, version = excluded.version`,
      e.id, JSON.stringify(e.view), e.view.auto ? 1 : 0, e.view.blocked === "no_machine" ? 1 : 0, e.assignment?.kind ?? null, e.assignment?.machine ?? null, e.view.epoch, e.view.createdAt, e.view.version
    )
    if (!e.assignment) {
      if (e.view.blocked !== "no_machine") return null
      const set = await this.machine()
      if (set) return set
      openLook(this.sql, e.owner, Date.now())
      await this.arm()
      return null
    }
    // Open the machine's start for an assignment it has not seen, or when none is open (an earlier one ended).
    const fresh = !old || old.assign_kind !== e.assignment.kind || old.epoch !== e.view.epoch
    if (fresh || !hasStart(this.sql, e.assignment.machine)) {
      openStart(this.sql, { machine: e.assignment.machine, team: e.assignment.team, owner: e.owner }, Date.now())
      await this.arm()
    }
    for (const wake of [...this.waiters]) wake()
    return null
  }

  /**
   * Newest first; `before` is the last row of the previous page. Closed chats are not listed. The owner asking for
   * their first page is also a moment to look for a machine for the chats that wait for one.
   */
  async list(owner: string, limit: number, before?: AutoListCursor): Promise<{ readonly sessions: ReadonlyArray<AutoSessionView>; readonly next: AutoListCursor | null }> {
    if (!before && !this.stored()) for (const team of this.waitingTeams(owner)) if (await this.autoMachine(owner, team)) break
    const rows = (before
      ? this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 AND (created_at < ? OR (created_at = ? AND id < ?)) ORDER BY created_at DESC, id DESC LIMIT ?`, before.createdAt, before.createdAt, before.id, limit + 1)
      : this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 ORDER BY created_at DESC, id DESC LIMIT ?`, limit + 1)
    ).toArray()
    const page = rows.slice(0, limit)
    const last = page.at(-1)
    return { sessions: page.map((r) => JSON.parse(r.view) as AutoSessionView), next: rows.length > limit && last ? { createdAt: last.created_at, id: last.id } : null }
  }

  private stored(): Stored | null {
    const row = this.sql.exec<{ team: string; machine: string; picked: number }>(`SELECT team, machine, picked FROM machine WHERE k = 1`).toArray()[0]
    return row ? { team: row.team, machine: row.machine, picked: row.picked === 1 } : null
  }

  /** The Auto machine as it is stored, named or picked. Readers that may need one found call `autoMachine`. */
  async machine(): Promise<AutoMachine | null> {
    return plain(this.stored())
  }

  /**
   * The owner's Auto machine, for every reader: a lease that ran out, a chat made with no laptop, a message for a
   * parked chat, a release, `GET /v1/auto-sessions/machine`. The machine the owner named is answered as it is.
   * With none, the owner's own machines in `team` (the chat's team, else the caller's; the owner's personal team
   * when that is unknown) are read and one is picked and kept (machine-pick.ts); the chats that waited go to it.
   * A kept pick is read again at most every PICK_CHECK_MS and replaced when it is gone. A look that found nothing
   * is not repeated for LOOK_MIN_MS.
   */
  async autoMachine(owner: string, team: string | null): Promise<AutoMachine | null> {
    const set = this.stored()
    if (set && !set.picked) return plain(set)
    const where = set?.team ?? team ?? personalTeamIdFor(owner)
    const under = this.looking.get(where)
    if (under) return under
    if (Date.now() - (this.looked.get(where) ?? -Infinity) < (set ? PICK_CHECK_MS : LOOK_MIN_MS)) return plain(set)
    return this.look(owner, where)
  }

  /** One read of the owner's machines in `team`, whatever the last one said. */
  private look(owner: string, team: string): Promise<AutoMachine | null> {
    this.looked.set(team, Date.now())
    const read = this.find(owner, team).finally(() => this.looking.delete(team))
    this.looking.set(team, read)
    return read
  }

  /** Reads the owner's machines in `team` and keeps what they say: the pick, a new one, or none. Never throws: a read that fails changes nothing. */
  private async find(owner: string, team: string): Promise<AutoMachine | null> {
    const before = this.stored()
    let found: string | null | undefined
    try {
      // A team the owner may not use (any more) has no machine for them, whatever it holds.
      found = (await mayUseTeam(this.env, owner, team)) ? await findMachine(wakeCloud(this.env)(team), owner, team, before?.picked ? before.machine : null) : null
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.machine_look_failed", error: String(e).slice(0, 200) }))
    }
    const now = this.stored()
    // The owner named a machine, or another look kept one, while this one read: that stands.
    if (now?.machine !== before?.machine || now?.picked !== before?.picked) return plain(now)
    if (found === undefined || found === (now?.machine ?? null)) return plain(now)
    if (found === null) {
      console.log(JSON.stringify({ msg: "auto_sessions.machine_pick_gone", machine: now?.machine }))
      this.sql.exec(`DELETE FROM machine WHERE k = 1`)
      return null
    }
    const picked = { team, machine: found }
    console.log(JSON.stringify({ msg: "auto_sessions.machine_picked", machine: found, replaced: now?.machine ?? null }))
    await this.keep(owner, picked, true)
    await this.send(owner, picked)
    return picked
  }

  private async keep(owner: string, m: AutoMachine, picked: boolean): Promise<void> {
    this.sql.exec(`INSERT INTO machine (k, team, machine, picked) VALUES (1, ?, ?, ?) ON CONFLICT (k) DO UPDATE SET team = excluded.team, machine = excluded.machine, picked = excluded.picked`, m.team, m.machine, picked ? 1 : 0)
    if (this.assigned(m.machine).length === 0 || hasStart(this.sql, m.machine)) return
    openStart(this.sql, { machine: m.machine, team: m.team, owner }, Date.now())
    await this.arm()
  }

  /** Sets the owner's Auto machine as the one they named. Setting it again is also how the owner asks for another try: a start that gave up while the machine still has something to pick up opens again. */
  async setMachine(owner: string, m: AutoMachine): Promise<void> {
    await this.keep(owner, m, false)
  }

  /** `PUT /v1/auto-sessions/machine`: the owner names their Auto machine, and the chats that waited for one go to it. It replaces a pick, and is never replaced by one. */
  async nameMachine(owner: string, m: AutoMachine): Promise<void> {
    await this.setMachine(owner, m)
    await this.send(owner, m)
  }

  /**
   * The chats that waited for a machine, or were given to another that never picked them up, go to `m`. A page at
   * a time, until a page comes back the same (a chat that could not be reached is told by its own index write
   * later).
   */
  private async send(owner: string, m: AutoMachine): Promise<void> {
    const chats = this.env.AUTO_SESSION_DO!
    let last = ""
    for (let page = 0; page < 10; page++) {
      const ids = await this.waitingFor(m.machine)
      if (ids.length === 0 || ids.join() === last) break
      last = ids.join()
      await Promise.allSettled(ids.map((id) => chats.get(chats.idFromName(`${owner}/${id}`)).machineSet(owner, m)))
    }
  }

  /**
   * The chats that go to the owner's Auto machine once it is set (at most 100 a call): those that waited for one,
   * and those given to another machine that has not picked them up. Read only when the machine is set or picked.
   */
  async waitingFor(machine: string): Promise<ReadonlyArray<string>> {
    return this.sql
      .exec<{ id: string }>(`SELECT id FROM sessions WHERE auto = 1 AND (blocked = 1 OR (assign_kind IN ('takeover', 'create') AND assign_machine != ?)) ORDER BY created_at, id LIMIT 100`, machine)
      .toArray()
      .map((r) => r.id)
  }

  /** The teams of the chats that wait for a machine (a chat with no team is in its owner's personal one), oldest chat first. */
  private waitingTeams(owner: string): ReadonlyArray<string> {
    const views = this.sql.exec<{ view: string }>(`SELECT view FROM sessions WHERE auto = 1 AND blocked = 1 ORDER BY created_at, id LIMIT 100`).toArray()
    return [...new Set(views.map((r) => (JSON.parse(r.view) as AutoSessionView).team ?? personalTeamIdFor(owner)))].slice(0, MAX_LOOK_TEAMS)
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

  /** The alarm: one look at each machine whose start is due, and the look for a machine when that is due. Never throws: a step that fails backs off by itself. */
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
    try {
      await this.lookDue()
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.look_step_failed", error: String(e).slice(0, 200) }))
      this.sql.exec(`UPDATE look SET next_at = ? WHERE next_at <= ?`, Date.now() + STEP_RETRY_MS, Date.now())
    }
    await this.arm().catch(() => undefined)
  }

  /**
   * The alarm's look for a machine, open while a chat waits for one (`put`). It ends when a machine is there (the
   * chats that still wait are sent to it), when no chat waits any more, or after GIVE_UP_MS; until then each look
   * that finds nothing waits longer before the next. A chat that waits past the end is found a machine at its
   * owner's next call for it or for their list.
   */
  private async lookDue(): Promise<void> {
    const row = dueLook(this.sql, Date.now())
    if (!row) return
    const teams = this.waitingTeams(row.owner)
    let set = await this.machine()
    if (set && teams.length > 0) await this.send(row.owner, set)
    if (!set && teams.length > 0 && Date.now() - row.since < GIVE_UP_MS) {
      for (const team of teams) if ((set = await (this.looking.get(team) ?? this.look(row.owner, team)))) break
      if (!set) return missLook(this.sql, row, Date.now())
    }
    closeLook(this.sql)
  }
}
