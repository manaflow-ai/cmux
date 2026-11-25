import type { Principal } from "@cmux/ownership"
import type { Env } from "./env.ts"
import { platformCloud, type PlatformCloud } from "./platform-cloud.ts"

/**
 * Wake on message for a Chief on its own Cloud machine (cmuxterm-hq RFD 0037, launch gate 1; RFD 0028's open
 * question). `machine.chief_start` places the Chief with `brain_place {host, install, machine, team}` and lets the
 * machine pause when idle. A message for it lands here, in its MuxDO, as a wake row that stays until the machine's
 * Chief host acks it (`mux.ack`), so a paused machine loses nothing: this module only gets the host back.
 *
 * On a new wake while the machine is not running, MuxDO starts it (`cloud.machine.start` as the owner's session,
 * the same op and key shape as chief-brain/brain-machine.ts wakeDefaultMachine) and the sender sees a live
 * "Waking" line in the conversation. One row per Chief (`mux_machine_wake`) keeps the attempt; MuxDO's alarm
 * reads the machine again every POLL_MS while it starts, and on a failed read or start backs off (1 s doubling to
 * 60 s) for up to GIVE_UP_MS. The line ends when the host acks (the Chief took the message) or once the machine has
 * run for RUNNING_GRACE_MS. A start that keeps failing never drops the message: the wake row stays, and the next
 * message (or the host's own start) delivers it.
 */
export const POLL_MS = 5_000
const MAX_BACKOFF_MS = 60_000
export const GIVE_UP_MS = 6 * 3600_000
/** After the machine runs, how long the line waits for the host's ack before it ends anyway. */
export const RUNNING_GRACE_MS = 120_000
/** How long to wait after failed try number `tries` (1 s doubling to 60 s). Auto mode's machine start shares it (auto-sessions/machine-start.ts). */
export const wakeBackoffMs = (tries: number): number => Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** Math.min(tries - 1, 16))
/** The line the sender sees while the machine resumes. */
export const WAKING_LINE = "Waking"

/** The Cloud machine a placed Chief runs on (user-chief.ts ChiefBrainPlace with `machine` and `team`). */
export interface PlacedMachine {
  readonly machine: string
  readonly team: string
}

/** The machine of a `brain_place`, or null for a place that names none (a server that is no Cloud machine). */
export const placedMachine = (place: unknown): PlacedMachine | null => {
  const p = place as { machine?: unknown; team?: unknown } | null | undefined
  return p && typeof p.machine === "string" && p.machine && typeof p.team === "string" && p.team ? { machine: p.machine, team: p.team } : null
}

export interface WakeRow {
  readonly machine: string
  readonly team: string
  readonly conversation: string
  readonly run: string
  readonly since: number
  readonly tries: number
  readonly next_at: number
  /** When the machine was first seen running, or 0. */
  readonly running_at: number
  /** The sender saw the "Waking" line (its end is due when the wake closes). */
  readonly shown: boolean
}

/** What one read of the machine says to do next. */
export type WakeStep =
  | { readonly act: "start"; readonly revision: string }
  | { readonly act: "wait" }
  | { readonly act: "running" }
  | { readonly act: "retry"; readonly error: string }

/** The pure decision from a `cloud.machine.get` answer (status, revision) or its failure. */
export const wakeStep = (read: { ok: true; value: unknown; revision?: string } | { ok: false; code?: string; message?: string }): WakeStep => {
  if (!read.ok) return { act: "retry", error: read.code ?? read.message ?? "machine read failed" }
  const v = read.value as { status?: unknown; machine?: { status?: unknown } } | null
  const status = typeof v?.status === "string" ? v.status : typeof v?.machine?.status === "string" ? v.machine.status : ""
  if (status === "running") return { act: "running" }
  if (status === "starting" || status === "pausing" || status === "provisioning" || status === "resuming") return { act: "wait" }
  if (status === "paused" || status === "stopped") {
    if (typeof read.revision !== "string" || !read.revision) return { act: "retry", error: "machine revision missing" }
    return { act: "start", revision: read.revision }
  }
  return { act: "retry", error: `machine ${status || "unknown"}` }
}

const ready = new WeakSet<SqlStorage>()
const table = (sql: SqlStorage) => {
  if (ready.has(sql)) return
  sql.exec(`CREATE TABLE IF NOT EXISTS mux_machine_wake (k INTEGER PRIMARY KEY CHECK (k = 1), machine TEXT NOT NULL, team TEXT NOT NULL, conversation TEXT NOT NULL, run TEXT NOT NULL, since INTEGER NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, running_at INTEGER NOT NULL DEFAULT 0, shown INTEGER NOT NULL DEFAULT 0)`)
  ready.add(sql)
}

export const readWake = (sql: SqlStorage): WakeRow | null => {
  table(sql)
  const r = sql.exec<Record<string, string | number>>(`SELECT machine, team, conversation, run, since, tries, next_at, running_at, shown FROM mux_machine_wake WHERE k = 1`).toArray()[0]
  return r ? { machine: String(r.machine), team: String(r.team), conversation: String(r.conversation), run: String(r.run), since: Number(r.since), tries: Number(r.tries), next_at: Number(r.next_at), running_at: Number(r.running_at), shown: Number(r.shown) === 1 } : null
}

/** When the alarm should read the machine again, or null. */
export const machineWakeAt = (sql: SqlStorage): number | null => readWake(sql)?.next_at ?? null

/** Starts (or joins) a wake for a new message in `conversation`; returns the row. A running wake keeps its line. */
export const openWake = (sql: SqlStorage, m: PlacedMachine, conversation: string, now: number): WakeRow => {
  table(sql)
  sql.exec(`INSERT INTO mux_machine_wake (k, machine, team, conversation, run, since, next_at) VALUES (1, ?, ?, ?, ?, ?, ?) ON CONFLICT (k) DO UPDATE SET next_at = MIN(next_at, excluded.next_at)`, m.machine, m.team, conversation, `wake_${now}`, now, now)
  return readWake(sql)!
}

export const closeWake = (sql: SqlStorage): WakeRow | null => {
  const row = readWake(sql)
  if (row) sql.exec(`DELETE FROM mux_machine_wake WHERE k = 1`)
  return row
}

/** The sender's view: the live line while the machine wakes, and its end. Best effort (never stored there). */
export interface WakeView {
  waking(row: WakeRow, now: number): Promise<void>
  ended(row: WakeRow, now: number): Promise<void>
}

/** The calls this module makes on cmux-platform's CloudDO (platform-cloud.ts). */
export type WakeCloud = Pick<PlatformCloud, "readOp" | "submit">

/**
 * One turn of the wake for Chief `agent` of `owner`: read the machine, start it when paused, and settle the row.
 * `pending`: the Chief's unacked wake rows (MuxDO head); none left means the host took the message.
 */
export const stepWake = async (sql: SqlStorage, cloud: (team: string) => WakeCloud, view: WakeView, agent: string, owner: string, pending: number, now: number): Promise<void> => {
  const row = readWake(sql)
  if (!row) return
  if (pending === 0 || now - row.since >= GIVE_UP_MS) {
    if (pending > 0) console.error(JSON.stringify({ msg: "chief_machine.wake_gave_up", agent, machine: row.machine, tries: row.tries }))
    closeWake(sql)
    return row.shown ? view.ended(row, now) : undefined
  }
  if (row.running_at > 0 && now - row.running_at >= RUNNING_GRACE_MS) {
    // Running and still no ack: the host is late, not the machine. The wake row waits for it.
    closeWake(sql)
    return row.shown ? view.ended(row, now) : undefined
  }
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner, team: row.team }
  const c = cloud(row.team)
  let step: WakeStep
  try {
    step = wakeStep(await c.readOp(row.team, principal, "cloud.machine.get", { machine: row.machine }) as Parameters<typeof wakeStep>[0])
    if (step.act === "start") {
      const reply = await c.submit(row.team, principal, { t: "op", op: "cloud.machine.start", params: { machine: row.machine }, idempotency_key: `chief-machine-wake:${agent}:${row.machine}:${step.revision}`, origin: "script" })
      const result = reply.frames.find((f) => f.t === "result" || f.t === "reject") as { t: string; code?: string } | undefined
      if (!result || result.t === "reject") step = { act: "retry", error: result?.code ?? "cloud.machine.start unanswered" }
    }
  } catch (e) {
    step = { act: "retry", error: String(e).slice(0, 200) }
  }
  // Running at the first look: the host is up and takes the message itself; no wake, no line.
  if (step.act === "running" && !row.shown && row.tries === 0) {
    closeWake(sql)
    return
  }
  if (step.act === "retry") {
    const tries = row.tries + 1
    console.warn(JSON.stringify({ msg: "chief_machine.wake_retry", agent, machine: row.machine, tries, error: step.error }))
    sql.exec(`UPDATE mux_machine_wake SET tries = ?, next_at = ? WHERE k = 1`, tries, now + wakeBackoffMs(tries))
  } else {
    const running = step.act === "running" ? row.running_at || now : 0
    if (step.act === "start") console.log(JSON.stringify({ msg: "chief_machine.wake_start", agent, machine: row.machine }))
    sql.exec(`UPDATE mux_machine_wake SET tries = 0, next_at = ?, running_at = ? WHERE k = 1`, now + POLL_MS, running)
  }
  if (!row.shown) {
    sql.exec(`UPDATE mux_machine_wake SET shown = 1 WHERE k = 1`)
    await view.waking(row, now)
  }
}

/** The live client for a team's CloudDO. */
export const wakeCloud = (env: Env) => (team: string): WakeCloud => platformCloud(env.CLOUD_DO, team)
