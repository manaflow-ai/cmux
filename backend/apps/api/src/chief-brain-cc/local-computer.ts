import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import type { Env } from "../env.ts"
import { sandboxesOf } from "./sandbox.ts"

/**
 * The computer of a Chief that runs on its owner's Mac (a "local Chief"): the same Chief computer a Cloud Chief has
 * (sandbox.ts COMPUTER_SIZE, sandbox-computer.ts, its TTL, lease and take-over), on a sandboxes object keyed by the
 * signed-in owner and the Mac's own id for that Chief instead of an `agent_` record, which a local Chief does not have.
 *
 * - The key is built on the server from the session's user (localComputerKey): a caller can only ever reach its own
 *   Chiefs' computers, whatever Chief id it sends.
 * - It is a Chief sandbox, never one of the team's Cloud machines, so it does not count toward the Cloud plan's machine
 *   limit; the owner's plan is checked as for a Cloud Chief (`cloud.plan.required`, sandbox-plan.ts).
 * - So that exemption cannot be stacked, one owner holds at most LOCAL_COMPUTER_CAP local-Chief computers at a time
 *   (made or being made), counted on the owner's own registry object (reserveLocalComputer), refused with
 *   `computer.local_limit`.
 */
export const LOCAL_COMPUTER_CAP = 3
/** A local Chief's id as the Mac sends it: its conversation or registry id. */
export const LOCAL_CHIEF_ID = /^[A-Za-z0-9_-]{1,64}$/
/** A reservation this young holds its slot even before the provision it was made for shows (it starts right after). */
const RESERVE_HOLD_MS = 10 * 60_000
const REGISTRY = "cc_local_computers"

/** The sandboxes key of owner `user`'s local Chief `chief`: never an `agent_` id, never another owner's. */
export const localComputerKey = (user: string, chief: string): string => `local:${user}:${chief}`
/** The owner's registry of local-Chief computers (one object per owner). */
export const localRegistryOf = (env: Env, user: string) => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(`local:${user}/computers`))

type Reservation = { chief: string; at: number }

const listOf = (b: ChiefBrainDO): Array<Reservation> => {
  const raw = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = ?`, REGISTRY).toArray()[0]?.value
  try {
    const xs = JSON.parse(raw ?? "[]") as Array<Reservation>
    return Array.isArray(xs) ? xs.filter((x) => typeof x?.chief === "string" && typeof x?.at === "number") : []
  } catch {
    return []
  }
}

/** One reservation at a time per owner: two Chiefs asked at once both count. */
const locks = new WeakMap<object, Promise<unknown>>()
const serial = <T>(b: ChiefBrainDO, fn: () => Promise<T>): Promise<T> => {
  const next = (locks.get(b.sql) ?? Promise.resolve()).catch(() => undefined).then(fn)
  locks.set(b.sql, next)
  return next
}

/**
 * Reserves a computer slot for owner `user`'s local Chief `chief` on the owner's registry object: the other Chiefs that
 * still hold one (a computer, one being made, or a reservation younger than RESERVE_HOLD_MS) count; one whose computer is
 * gone frees its slot. The Chief asking is never counted against itself (its own computer, or a retry, is not a second).
 */
export const reserveLocalComputer = (b: ChiefBrainDO, user: string, chief: string, cap = LOCAL_COMPUTER_CAP, now = Date.now()): Promise<{ ok: true } | { ok: false; held: number }> =>
  serial(b, async () => {
    const held: Array<Reservation> = []
    for (const r of listOf(b)) {
      if (r.chief === chief) continue
      if (now - r.at < RESERVE_HOLD_MS) {
        held.push(r)
        continue
      }
      const key = localComputerKey(user, r.chief)
      const s = await sandboxesOf(b.doEnv, key).ccComputerStatus(key, user).catch(() => null)
      // A status that did not answer keeps its slot: the cap holds when Freestyle is slow.
      if (!s || s.computer || s.provisioning) held.push(r)
    }
    if (held.length >= cap) return { ok: false as const, held: held.length }
    writeConfig(b.sql, { [REGISTRY]: JSON.stringify([...held, { chief, at: now }]) })
    return { ok: true as const }
  })

/** Gives back owner's local Chief `chief`'s slot: its provision was refused or failed, or its computer was deleted. */
export const releaseLocalComputer = (b: ChiefBrainDO, chief: string): Promise<void> =>
  serial(b, async () => {
    const list = listOf(b)
    const left = list.filter((r) => r.chief !== chief)
    if (left.length !== list.length) writeConfig(b.sql, { [REGISTRY]: JSON.stringify(left) })
  })
