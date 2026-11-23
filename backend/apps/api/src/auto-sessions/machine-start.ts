import type { Principal } from "@cmux/ownership"
import { GIVE_UP_MS, POLL_MS, RUNNING_GRACE_MS, wakeBackoffMs, wakeStep, type WakeCloud, type WakeStep } from "../mux-machine-wake.ts"

/**
 * Starting a paused Cloud machine for Auto chats it was given (DESIGN.md "Lease"). The owner's AutoSessionIndexDO
 * keeps one start per machine, not one per chat: a laptop that closes with ten chats at work starts its machine
 * once. The start is the wake of mux-machine-wake.ts with the same decision (`wakeStep`), poll and backoff:
 * read the machine as its owner, start it when paused (`cloud.machine.start`), read again every POLL_MS while it
 * starts, and on a failed read or start wait 1 s doubling to 60 s, for up to GIVE_UP_MS.
 *
 * A start never owns an assignment. Each stays on its chat until the machine acks it, so a start that fails or
 * gives up loses nothing: the next assignment for the machine opens a new one.
 */
export type StartRow = {
  readonly machine: string
  readonly team: string
  readonly owner: string
  readonly since: number
  readonly tries: number
  readonly next_at: number
  /** When the machine was first seen running, or 0. */
  readonly running_at: number
  /** The machine was seen not running, so this start had something to do. */
  readonly asked: number
}

export const STARTS_TABLE = `CREATE TABLE IF NOT EXISTS starts (machine TEXT PRIMARY KEY, team TEXT NOT NULL, owner TEXT NOT NULL, since INTEGER NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, running_at INTEGER NOT NULL DEFAULT 0, asked INTEGER NOT NULL DEFAULT 0)`

export const hasStart = (sql: SqlStorage, machine: string): boolean => sql.exec(`SELECT 1 FROM starts WHERE machine = ?`, machine).toArray().length > 0

/** Opens the machine's start, or brings a waiting one forward to now. */
export const openStart = (sql: SqlStorage, m: { readonly machine: string; readonly team: string; readonly owner: string }, now: number): void =>
  void sql.exec(`INSERT INTO starts (machine, team, owner, since, next_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT (machine) DO UPDATE SET team = excluded.team, next_at = min(next_at, excluded.next_at)`, m.machine, m.team, m.owner, now, now)

export const dueStarts = (sql: SqlStorage, now: number): ReadonlyArray<StartRow> => sql.exec<StartRow>(`SELECT * FROM starts WHERE next_at <= ? ORDER BY next_at`, now).toArray()

/** When the alarm should look at a machine again, or null. */
export const nextStartAt = (sql: SqlStorage): number | null => sql.exec<{ at: number | null }>(`SELECT min(next_at) AS at FROM starts`).toArray()[0]?.at ?? null

const closeStart = (sql: SqlStorage, machine: string): void => void sql.exec(`DELETE FROM starts WHERE machine = ?`, machine)

/**
 * One look at `row`'s machine. `pending`: the assignments it has not acked; none left ends the start. `mayUse`
 * asks again that the owner may still use the machine's team, so a start never outlives a removal from it.
 */
export const stepStart = async (sql: SqlStorage, cloud: (team: string) => WakeCloud, mayUse: (owner: string, team: string) => Promise<boolean>, row: StartRow, pending: number, now: number): Promise<void> => {
  if (pending === 0) return closeStart(sql, row.machine)
  if (now - row.since >= GIVE_UP_MS) {
    console.error(JSON.stringify({ msg: "auto_sessions.start_gave_up", machine: row.machine, tries: row.tries }))
    return closeStart(sql, row.machine)
  }
  // Running and still no ack: the machine's daemon is late, not the machine. The assignments wait for it.
  if (row.running_at > 0 && now - row.running_at >= RUNNING_GRACE_MS) return closeStart(sql, row.machine)
  const principal: Principal = { identity: `session:${row.owner}`, kind: "session", user: row.owner, team: row.team }
  let step: WakeStep
  try {
    if (!(await mayUse(row.owner, row.team))) {
      console.warn(JSON.stringify({ msg: "auto_sessions.start_refused", machine: row.machine, reason: "the owner no longer has the machine's team" }))
      return closeStart(sql, row.machine)
    }
    const c = cloud(row.team)
    step = wakeStep((await c.readOp(row.team, principal, "cloud.machine.get", { machine: row.machine })) as Parameters<typeof wakeStep>[0])
    if (step.act === "start") {
      const reply = await c.submit(row.team, principal, { t: "op", op: "cloud.machine.start", params: { machine: row.machine }, idempotency_key: `auto-session-start:${row.owner}:${row.machine}:${step.revision}`, origin: "script" })
      const result = reply.frames.find((f) => f.t === "result" || f.t === "reject") as { t: string; code?: string } | undefined
      if (!result || result.t === "reject") step = { act: "retry", error: result?.code ?? "cloud.machine.start unanswered" }
    }
  } catch (e) {
    step = { act: "retry", error: String(e).slice(0, 200) }
  }
  if (step.act === "retry") {
    const tries = row.tries + 1
    console.warn(JSON.stringify({ msg: "auto_sessions.start_retry", machine: row.machine, tries, error: step.error }))
    sql.exec(`UPDATE starts SET tries = ?, next_at = ?, asked = 1 WHERE machine = ?`, tries, now + wakeBackoffMs(tries), row.machine)
    return
  }
  // Running at the first look: its daemon is up and reads its assignments itself.
  if (step.act === "running" && row.asked === 0) return closeStart(sql, row.machine)
  if (step.act === "start") console.log(JSON.stringify({ msg: "auto_sessions.start", machine: row.machine }))
  sql.exec(`UPDATE starts SET tries = 0, asked = 1, next_at = ?, running_at = ? WHERE machine = ?`, now + POLL_MS, step.act === "running" ? row.running_at || now : 0, row.machine)
}
