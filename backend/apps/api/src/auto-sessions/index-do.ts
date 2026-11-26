import { envForObject } from "../build-space.ts"
import { DurableObject } from "cloudflare:workers"
import { roleHas } from "../domains/team-roles.ts"
import { personalTeamIdFor } from "../domains/user.ts"
import type { Env, RawEnv } from "../env.ts"
import { GIVE_UP_MS, wakeCloud } from "../mux-machine-wake.ts"
import { closeLook, dueLook, findMachine, ownMachine, LOOK_MIN_MS, LOOK_TABLE, missLook, nextLookAt, openLook, PICK_CHECK_MS } from "./machine-pick.ts"
import { dueStarts, hasStart, nextStartAt, openStart, STARTS_TABLE, stepStart } from "./machine-start.ts"
import { dropPick, hasColumn, keepNamed, keepPick, namedMachine, openMachineTables, pickedMachine, sameMachine, storedMachine } from "./machine-store.ts"
import { MAX_WAIT_MS, type AssignmentKind, type AutoIndexEntry, type AutoMachine, type AutoSessionView } from "./model.ts"

export type AutoListCursor = { readonly createdAt: number; readonly id: string }
export type AutoAssignment = { readonly kind: AssignmentKind; readonly session: AutoSessionView }
type Row = { id: string; view: string; assign_kind: string | null; epoch: number; version: number; wake_machine: string | null }
/** How soon the alarm looks again after a start step could not run at all. */
const STEP_RETRY_MS = 5_000
/** The teams one look for a machine reads, at most. */
const MAX_LOOK_TEAMS = 3
/** The teams with a chat that waits that one look asks about, at most, to find the ones it reads. */
const MAX_TEAMS_ASKED = 20
/** The pages of 100 chats one move of chats to or off a machine goes through, at most. */
const MAX_SEND_PAGES = 10

/** Whether `owner` may use a Cloud machine of `team`: their personal team, or a shared team their role has resources in. */
export const mayUseTeam = async (env: Env, owner: string, team: string): Promise<boolean> =>
  team === personalTeamIdFor(owner) || roleHas((await env.TEAM_DO.get(env.TEAM_DO.idFromName(team)).memberRole(team, owner)) ?? undefined, "team.resources")

/**
 * AutoSessionIndexDO: one per owner (name = the owner's user id), the AccountIndexDO and HandoffIndexDO pattern.
 * It owns no chat: each AutoSessionDO writes its row here after its own change (a late, older write changes
 * nothing) and retries a lost write from its alarm. What it keeps:
 *
 * - The owner's Auto chats, newest first, for `GET /v1/auto-sessions`.
 * - The owner's Auto machines (machine-store.ts): the one they named (`PUT /v1/auto-sessions/machine`), for all
 *   their chats; else, per team, one of their own Cloud machines in that team that this object picks and keeps
 *   for the chats of that team (`autoMachine`, the one lookup every reader calls).
 * - The assignments a machine has not acked. A chat's row names the machine it was given to and what for, under an
 *   index on the machine, so a machine's `GET /v1/auto-sessions/assignments` reads its own rows and never scans
 *   the owner's chats. The wait is held here: a row that gains an assignment wakes it.
 * - One start per machine with an assignment waiting (machine-start.ts), and one look for a machine while a chat
 *   waits for one (machine-pick.ts), both stepped by this object's alarm.
 * - The machine a move waits on (`wake_machine`: the person asked to move the chat, move.ts). It is kept started
 *   as a machine with an assignment is: the Auto machine, so it is up when the laptop gives the chat, or the
 *   machine that holds the chat and may be paused, so it reads the wish and gives.
 */
export class AutoSessionIndexDO extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, raw: RawEnv) {
    super(ctx, envForObject(ctx, raw))
    const sql = ctx.storage.sql
    sql.exec(`CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, view TEXT NOT NULL, auto INTEGER NOT NULL, blocked INTEGER NOT NULL DEFAULT 0, assign_kind TEXT, assign_machine TEXT, epoch INTEGER NOT NULL, created_at INTEGER NOT NULL, version INTEGER NOT NULL, team TEXT, wake_machine TEXT)`)
    // An object made before a chat could be moved by hand has no machine a move waits on: none of its chats has one.
    if (!hasColumn(sql, "sessions", "wake_machine")) sql.exec(`ALTER TABLE sessions ADD COLUMN wake_machine TEXT`)
    // An object made before a pick was kept per team has its rows without the chat's team: each row's view has it.
    if (!hasColumn(sql, "sessions", "team")) {
      sql.exec(`ALTER TABLE sessions ADD COLUMN team TEXT`)
      for (const r of sql.exec<{ id: string; view: string }>(`SELECT id, view FROM sessions`).toArray()) sql.exec(`UPDATE sessions SET team = ? WHERE id = ?`, (JSON.parse(r.view) as AutoSessionView).team ?? null, r.id)
    }
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_newest ON sessions (created_at DESC, id DESC)`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_assigned ON sessions (assign_machine) WHERE assign_kind IS NOT NULL`)
    sql.exec(`CREATE INDEX IF NOT EXISTS sessions_woken ON sessions (wake_machine) WHERE wake_machine IS NOT NULL`)
    openMachineTables(sql)
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
   * A chat's row after its change. A new assignment opens its machine's start and wakes the machine's wait. The
   * answer is the Auto machine the chat should go to, when it is not there:
   *
   * - To a chat that waits for a machine: the one stored for it (named, else its team's pick). The chat was parked
   *   while the machine was being set, and goes to it now. With none, the alarm starts looking for one.
   * - To a chat given to a machine that is not the one stored for it, and never picked up there: the stored one.
   *   So a move of the owner's chats that crossed another (a pick being sent while the owner named a machine)
   *   ends with every chat on the machine that is stored, whichever word reached the chat last.
   *
   * A row that names a machine a move waits on (`wake`) opens that machine's start too, once per wish.
   */
  async put(e: AutoIndexEntry): Promise<AutoMachine | null> {
    const old = this.sql.exec<Row>(`SELECT id, view, assign_kind, epoch, version, wake_machine FROM sessions WHERE id = ?`, e.id).toArray()[0]
    if (old && old.version >= e.view.version) return null
    this.sql.exec(
      `INSERT INTO sessions (id, view, auto, blocked, assign_kind, assign_machine, epoch, created_at, version, team, wake_machine) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT (id) DO UPDATE SET view = excluded.view, auto = excluded.auto, blocked = excluded.blocked, assign_kind = excluded.assign_kind, assign_machine = excluded.assign_machine, epoch = excluded.epoch, version = excluded.version, team = excluded.team, wake_machine = excluded.wake_machine`,
      e.id, JSON.stringify(e.view), e.view.auto ? 1 : 0, e.view.blocked === "no_machine" ? 1 : 0, e.assignment?.kind ?? null, e.assignment?.machine ?? null, e.view.epoch, e.view.createdAt, e.view.version, e.view.team, e.wake?.machine ?? null
    )
    if (e.wake && (old?.wake_machine !== e.wake.machine || !hasStart(this.sql, e.wake.machine))) {
      openStart(this.sql, { machine: e.wake.machine, team: e.wake.team, owner: e.owner }, Date.now())
      await this.arm()
    }
    const team = e.view.team ?? personalTeamIdFor(e.owner)
    if (!e.assignment) {
      if (e.view.blocked !== "no_machine") return null
      const set = storedMachine(this.sql, team)
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
    // A machine that was heard from keeps its chat (lease.ts `machineSet`): `leaseExpiresAt` is 0 until then.
    if (e.assignment.kind === "deliver" || e.view.leaseExpiresAt !== 0) return null
    const set = storedMachine(this.sql, team)
    return set && set.machine !== e.assignment.machine ? set : null
  }

  /**
   * Newest first; `before` is the last row of the previous page. Closed chats are not listed. The owner asking for
   * their first page is also a moment to look for a machine for the chats that wait for one, each in its own team.
   */
  async list(owner: string, limit: number, before?: AutoListCursor): Promise<{ readonly sessions: ReadonlyArray<AutoSessionView>; readonly next: AutoListCursor | null }> {
    if (!before && !namedMachine(this.sql)) for (const team of (await this.waitingTeams(owner)).teams) await this.autoMachine(owner, team)
    const rows = (before
      ? this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 AND (created_at < ? OR (created_at = ? AND id < ?)) ORDER BY created_at DESC, id DESC LIMIT ?`, before.createdAt, before.createdAt, before.id, limit + 1)
      : this.sql.exec<{ id: string; view: string; created_at: number }>(`SELECT id, view, created_at FROM sessions WHERE auto = 1 ORDER BY created_at DESC, id DESC LIMIT ?`, limit + 1)
    ).toArray()
    const page = rows.slice(0, limit)
    const last = page.at(-1)
    return { sessions: page.map((r) => JSON.parse(r.view) as AutoSessionView), next: rows.length > limit && last ? { createdAt: last.created_at, id: last.id } : null }
  }

  /**
   * The owner's Auto machine for a chat of `team` (the chat's team, else the caller's; the owner's personal team
   * when that is unknown), for every reader: a lease that ran out, a chat made with no laptop, a message for a
   * parked chat, a release, `GET /v1/auto-sessions/machine`. The machine the owner named is answered as it is,
   * whatever the team. With none, the answer is that team's pick and no other team's: the owner's own machines in
   * `team` are read and one is picked and kept for the team (machine-pick.ts); the team's chats that waited go to
   * it. A kept pick is read again at most every PICK_CHECK_MS and replaced when it is gone. A look that found
   * nothing is not repeated for LOOK_MIN_MS.
   */
  async autoMachine(owner: string, team: string | null): Promise<AutoMachine | null> {
    const named = namedMachine(this.sql)
    if (named) return named
    const where = team ?? personalTeamIdFor(owner)
    const under = this.looking.get(where)
    if (under) return under
    const pick = pickedMachine(this.sql, where)
    if (Date.now() - (this.looked.get(where) ?? -Infinity) < (pick ? PICK_CHECK_MS : LOOK_MIN_MS)) return pick
    return this.look(owner, where)
  }

  /** One read of the owner's machines in `team`, whatever the last one said; a read under way is joined. */
  private look(owner: string, team: string): Promise<AutoMachine | null> {
    const under = this.looking.get(team)
    if (under) return under
    this.looked.set(team, Date.now())
    const read = this.find(owner, team).finally(() => this.looking.delete(team))
    this.looking.set(team, read)
    return read
  }

  /**
   * Reads the owner's machines in `team` and keeps what they say for the team: its pick, a new one, or none. The
   * answer is what is stored when it ends, not what it found: the owner may have named a machine meanwhile. Never
   * throws: a read that fails, or that could not tell, changes nothing.
   */
  private async find(owner: string, team: string): Promise<AutoMachine | null> {
    const before = pickedMachine(this.sql, team)
    let found: string | null | undefined
    try {
      // A team the owner may not use (any more) has no machine for them, whatever it holds.
      found = (await mayUseTeam(this.env, owner, team)) ? await findMachine(wakeCloud(this.env)(team), owner, team, before?.machine ?? null) : null
    } catch (e) {
      console.warn(JSON.stringify({ msg: "auto_sessions.machine_look_failed", error: String(e).slice(0, 200) }))
    }
    // The owner named a machine while this one read: that stands, and no pick is kept beside it.
    const named = namedMachine(this.sql)
    if (named) return named
    const now = pickedMachine(this.sql, team)
    if (found === undefined || found === (now?.machine ?? null)) return now
    if (found === null) {
      console.log(JSON.stringify({ msg: "auto_sessions.machine_pick_gone", machine: now?.machine }))
      dropPick(this.sql, team)
      // The chats it was given and never picked up wait for a machine again, so one made later reaches them.
      if (now) await this.unassign(owner, now.machine)
      return storedMachine(this.sql, team)
    }
    const picked = { team, machine: found }
    console.log(JSON.stringify({ msg: "auto_sessions.machine_picked", machine: found, replaced: now?.machine ?? null }))
    keepPick(this.sql, picked)
    await this.startFor(owner, picked)
    await this.send(owner, picked, true)
    return storedMachine(this.sql, team)
  }

  /** Opens `m`'s start when it has something to pick up and none is open. */
  private async startFor(owner: string, m: AutoMachine): Promise<void> {
    if (this.assigned(m.machine).length === 0 || hasStart(this.sql, m.machine)) return
    openStart(this.sql, { machine: m.machine, team: m.team, owner }, Date.now())
    await this.arm()
  }

  /** Sets the owner's Auto machine as the one they named. Setting it again is also how the owner asks for another try: a start that gave up while the machine still has something to pick up opens again. */
  async setMachine(owner: string, m: AutoMachine): Promise<void> {
    keepNamed(this.sql, m)
    await this.startFor(owner, m)
  }

  /**
   * `PUT /v1/auto-sessions/machine`: the owner names their Auto machine, and the chats that waited for one go to it. It replaces every pick, and is
   * never replaced by one. Only a machine the store could have picked is named (machine-pick.ts `ownMachine`): `not_own` for any other, `unknown`
   * when the Cloud could not say, and nothing changes then.
   */
  async nameMachine(owner: string, m: AutoMachine): Promise<"named" | "not_own" | "unknown"> {
    const own = await ownMachine(wakeCloud(this.env)(m.team), owner, m.team, m.machine)
    if (own !== true) return own === false ? "not_own" : "unknown"
    await this.setMachine(owner, m)
    await this.send(owner, m, false)
    return "named"
  }

  /**
   * The chats that waited for a machine, or were given to another that never picked them up, go to `m`: all the
   * owner's for a machine they named, the chats of its team for a pick (`picked`). A page at a time, until a page
   * comes back the same (a chat that could not be reached is told by its own index write later). It stops before
   * a page once `m` is no longer what is stored (the owner named a machine while a pick was being sent, or
   * named another): what is stored now has its own send, and this one must not move its chats back.
   */
  private async send(owner: string, m: AutoMachine, picked: boolean): Promise<void> {
    const chats = this.env.AUTO_SESSION_DO!
    let last = ""
    for (let page = 0; page < MAX_SEND_PAGES; page++) {
      if (!sameMachine(picked ? storedMachine(this.sql, m.team) : namedMachine(this.sql), m)) return
      const ids = this.waitingFor(owner, m, picked)
      if (ids.length === 0 || ids.join() === last) break
      last = ids.join()
      await Promise.allSettled(ids.map((id) => chats.get(chats.idFromName(`${owner}/${id}`)).machineSet(owner, m, picked)))
    }
  }

  /**
   * The pick `machine` is gone and nothing replaced it: the chats given to it and never picked up are parked to
   * wait for a machine again (machine-gone.ts). Each then writes its row here as a chat that waits, which opens
   * the look that finds a machine made later.
   */
  private async unassign(owner: string, machine: string): Promise<void> {
    const chats = this.env.AUTO_SESSION_DO!
    let last = ""
    for (let page = 0; page < MAX_SEND_PAGES; page++) {
      const ids = this.sql.exec<{ id: string }>(`SELECT id FROM sessions WHERE auto = 1 AND assign_machine = ? AND assign_kind IN ('takeover', 'create') ORDER BY created_at, id LIMIT 100`, machine).toArray().map((r) => r.id)
      if (ids.length === 0 || ids.join() === last) break
      last = ids.join()
      await Promise.allSettled(ids.map((id) => chats.get(chats.idFromName(`${owner}/${id}`)).machineGone(owner, machine)))
    }
  }

  /**
   * The chats that go to `m` once it is set (at most 100 a call): those that waited for a machine, and those given
   * to another machine that has not picked them up. For a pick, only the chats of its team (a chat with no team is
   * in its owner's personal one).
   */
  private waitingFor(owner: string, m: AutoMachine, picked: boolean): ReadonlyArray<string> {
    const waits = `auto = 1 AND (blocked = 1 OR (assign_kind IN ('takeover', 'create') AND assign_machine != ?))`
    const rows = picked
      ? this.sql.exec<{ id: string }>(`SELECT id FROM sessions WHERE ${waits} AND COALESCE(team, ?) = ? ORDER BY created_at, id LIMIT 100`, m.machine, personalTeamIdFor(owner), m.team)
      : this.sql.exec<{ id: string }>(`SELECT id FROM sessions WHERE ${waits} ORDER BY created_at, id LIMIT 100`, m.machine)
    return rows.toArray().map((r) => r.id)
  }

  /**
   * The teams of the chats that wait for a machine (a chat with no team is in its owner's personal one), by their
   * oldest waiting chat, that the owner may use: at most MAX_LOOK_TEAMS, and `more` when another waits behind
   * them. A team the owner has left has no machine for them, so it takes no place among the ones that are read.
   */
  private async waitingTeams(owner: string): Promise<{ readonly teams: ReadonlyArray<string>; readonly more: boolean }> {
    const rows = this.sql
      .exec<{ of_team: string }>(`SELECT COALESCE(team, ?) AS of_team, min(created_at) AS oldest FROM sessions WHERE auto = 1 AND blocked = 1 GROUP BY of_team ORDER BY oldest, of_team LIMIT ?`, personalTeamIdFor(owner), MAX_TEAMS_ASKED)
      .toArray()
    const teams: Array<string> = []
    for (const { of_team: team } of rows) {
      // A membership that cannot be read now is left to the look itself, which reads it again and changes nothing if it fails.
      if (!(await mayUseTeam(this.env, owner, team).catch(() => true))) continue
      if (teams.length === MAX_LOOK_TEAMS) return { teams, more: true }
      teams.push(team)
    }
    return { teams, more: false }
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
        // What keeps a start open: an assignment the machine has not acked, or a move that waits on it.
        const pending = this.sql.exec(`SELECT 1 FROM sessions WHERE (assign_machine = ? AND assign_kind IS NOT NULL) OR wake_machine = ? LIMIT 1`, row.machine, row.machine).toArray().length
        const said = await stepStart(this.sql, wakeCloud(this.env), (owner, team) => mayUseTeam(this.env, owner, team), row, pending, Date.now())
        // The store's own pick does not exist any more: look now, which replaces it or leaves its chats waiting for
        // a machine. A machine the owner named is theirs to name again; its start goes on as it did.
        if (said === "gone" && pickedMachine(this.sql, row.team)?.machine === row.machine) await this.look(row.owner, row.team)
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
   * The alarm's look for a machine, open while a chat waits for one (`put`). Each team with a chat that waits is
   * read for its own machine, and the chats that still wait are sent to it. The look ends when every such team
   * has a machine, when no chat waits any more in a team the owner may use, or after GIVE_UP_MS; until then each
   * look that leaves a team without one waits longer before the next. A chat that waits past the end is found a
   * machine at its owner's next call for it or for their list.
   */
  private async lookDue(): Promise<void> {
    const row = dueLook(this.sql, Date.now())
    if (!row) return
    const { teams, more } = await this.waitingTeams(row.owner)
    const named = namedMachine(this.sql)
    if (named && teams.length > 0) await this.send(row.owner, named, false)
    if (named || teams.length === 0 || Date.now() - row.since >= GIVE_UP_MS) return closeLook(this.sql)
    let missed = more
    for (const team of teams) {
      // What the look answers is the team's pick, or the machine the owner named while it read.
      const set = await this.look(row.owner, team)
      if (set) await this.send(row.owner, set, !sameMachine(set, namedMachine(this.sql)))
      else missed = true
    }
    if (missed) return missLook(this.sql, row, Date.now())
    closeLook(this.sql)
  }
}
