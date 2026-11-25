import type { Principal } from "@cmux/ownership"
import type { WakeCloud } from "../mux-machine-wake.ts"
import { MACHINE } from "./http.ts"

/**
 * Finding the owner's Auto machine when they named none (DESIGN.md "Rules added after the correctness review").
 * No client has a step that names it, so the owner's AutoSessionIndexDO picks one of the owner's own Cloud
 * machines the first time a chat needs one, and keeps it for the chats of that team (machine-store.ts).
 *
 * The machines are read as the owner from the platform's CloudDO of one team: `cloud.machine.list`, the read the
 * start of machine-start.ts sits beside (`cloud.machine.get`), with the same principal. The list is the whole
 * team's, so the pick keeps only what the owner made. The team is the chat's, and a pick is answered only for a
 * chat of its team: a chat never goes to a machine of another team because some other chat needed one first.
 *
 * A pick is not for good the way a named machine is: a machine the owner deleted would keep every later chat
 * waiting, and nobody is there to name another. So a kept pick is read again (`cloud.machine.get`, at most every
 * PICK_CHECK_MS) when a chat needs it, and at once when its start is told the machine does not exist. A pick
 * that is gone is replaced by another of the owner's machines in the team; with none, the chats it was given and
 * never picked up wait for a machine again (machine-gone.ts).
 *
 * While a chat waits for a machine and none is found, the index's alarm looks again (`look` below): 15 s later,
 * then twice as long each time up to 10 minutes, for up to 6 hours. The owner's own calls look sooner.
 */
/** The least time between two looks in one team that found nothing. A chat's renewals never look. */
export const LOOK_MIN_MS = 10_000
/** How often a kept pick is read again, at most. */
export const PICK_CHECK_MS = 60_000
/** A team's machines are read at most this many pages of 100. */
const MAX_PAGES = 5
const MAX_LOOK_BACKOFF_MS = 600_000
/** How long the alarm waits after look number `tries` found nothing (15 s doubling to 10 minutes). */
export const lookBackoffMs = (tries: number): number => Math.min(MAX_LOOK_BACKOFF_MS, 15_000 * 2 ** Math.min(tries, 16))

/** The states a machine can be started from or is on its way to running in: never one being deleted, never a failed one. */
const USABLE = new Set(["running", "starting", "resuming", "provisioning", "pausing", "paused", "stopped"])

type Candidate = { readonly id: string; readonly running: boolean; readonly usedAt: number }

/** `machine` (a `CloudMachine` of the wire) when the owner's Auto chats may go to it: their own, usable, and not one still on cmux Cloud classic. */
const candidate = (machine: unknown, owner: string): Candidate | null => {
  const m = machine as { id?: unknown; creator?: unknown; status?: unknown; classic?: unknown; last_active_at?: unknown; created_at?: unknown } | null
  if (!m || typeof m.id !== "string" || !MACHINE.test(m.id) || m.creator !== owner || m.classic === true) return null
  if (typeof m.status !== "string" || !USABLE.has(m.status)) return null
  const at = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : 0)
  return { id: m.id, running: m.status === "running", usedAt: Math.max(at(m.last_active_at), at(m.created_at)) }
}

/** The pick among a team's machines: one that is running first, then the most recently used or made. Null when the owner has none. */
export const pickMachine = (machines: ReadonlyArray<unknown>, owner: string): string | null => {
  const best = machines
    .map((m) => candidate(m, owner))
    .filter((c): c is Candidate => c !== null)
    .sort((a, b) => Number(b.running) - Number(a.running) || b.usedAt - a.usedAt || (a.id < b.id ? -1 : 1))[0]
  return best?.id ?? null
}

/**
 * What the owner's machines in `team` say the Auto machine is. `kept`: the pick made earlier; it stays while the
 * owner can still use it, whatever else runs now. Answers the machine's id, null when the owner has none there,
 * and undefined when that could not be told (nothing is known, so nothing changes): the Cloud could not be read,
 * or the team has more machines than the MAX_PAGES pages read and none of the owner's was among them.
 */
export const findMachine = async (cloud: Pick<WakeCloud, "readOp">, owner: string, team: string, kept: string | null): Promise<string | null | undefined> => {
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner, team }
  if (kept) {
    const read = await cloud.readOp(team, principal, "cloud.machine.get", { machine: kept })
    if (!read.ok && read.code !== "cloud.machine.not_found") return undefined
    const value = read.ok ? (read.value as { machine?: unknown } | null) : null
    if (candidate(value?.machine ?? value, owner)) return kept
  }
  const machines: Array<unknown> = []
  let cursor: string | undefined
  for (let page = 0; page < MAX_PAGES; page++) {
    const read = await cloud.readOp(team, principal, "cloud.machine.list", { limit: 100, ...(cursor ? { cursor } : {}) })
    if (!read.ok) return undefined
    const value = read.value as { machines?: unknown; next_cursor?: unknown } | null
    if (Array.isArray(value?.machines)) machines.push(...value.machines)
    cursor = typeof value?.next_cursor === "string" && value.next_cursor ? value.next_cursor : undefined
    if (!cursor) break
  }
  // A list that goes on past the last page read was not read whole: one of the owner's machines among what was
  // read is a pick, but none there does not say the owner has none.
  return pickMachine(machines, owner) ?? (cursor ? undefined : null)
}

/**
 * Whether the owner may name `machine` of `team` as their Auto machine: the rule a pick follows (`candidate`), so a
 * named machine is one the owner made, usable and not classic (security review of cmux#52931, item 2). Without it
 * the owner could name a teammate's machine in a shared team, and that machine would be handed the owner's chats,
 * their copies and their messages. Undefined when the Cloud could not be read: nothing is named then.
 */
export const ownMachine = async (cloud: Pick<WakeCloud, "readOp">, owner: string, team: string, machine: string): Promise<boolean | undefined> => {
  const principal: Principal = { identity: `session:${owner}`, kind: "session", user: owner, team }
  const read = await cloud.readOp(team, principal, "cloud.machine.get", { machine })
  if (!read.ok) return read.code === "cloud.machine.not_found" ? false : undefined
  const value = read.value as { machine?: unknown } | null
  return candidate(value?.machine ?? value, owner)?.id === machine
}

/** The alarm's look for a machine, kept only while a chat waits for one: one row, like a machine's start. */
export type LookRow = { readonly owner: string; readonly since: number; readonly tries: number; readonly next_at: number }

export const LOOK_TABLE = `CREATE TABLE IF NOT EXISTS look (k INTEGER PRIMARY KEY CHECK (k = 1), owner TEXT NOT NULL, since INTEGER NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL)`

/** A chat waits for a machine: the alarm looks for one, starting over from the shortest wait. */
export const openLook = (sql: SqlStorage, owner: string, now: number): void =>
  void sql.exec(`INSERT INTO look (k, owner, since, next_at) VALUES (1, ?, ?, ?) ON CONFLICT (k) DO UPDATE SET since = excluded.since, tries = 0, next_at = min(next_at, excluded.next_at)`, owner, now, now + lookBackoffMs(0))

export const dueLook = (sql: SqlStorage, now: number): LookRow | null => sql.exec<LookRow>(`SELECT owner, since, tries, next_at FROM look WHERE k = 1 AND next_at <= ?`, now).toArray()[0] ?? null

/** When the alarm should look again, or null. */
export const nextLookAt = (sql: SqlStorage): number | null => sql.exec<{ next_at: number }>(`SELECT next_at FROM look WHERE k = 1`).toArray()[0]?.next_at ?? null

/** A look that found nothing waits longer before the next. */
export const missLook = (sql: SqlStorage, row: LookRow, now: number): void => void sql.exec(`UPDATE look SET tries = ?, next_at = ? WHERE k = 1`, row.tries + 1, now + lookBackoffMs(row.tries + 1))

export const closeLook = (sql: SqlStorage): void => void sql.exec(`DELETE FROM look WHERE k = 1`)
