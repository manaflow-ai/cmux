import { isDevice, type AutoCaller, type AutoRefusal } from "./model.ts"

/**
 * Which install a chat's `device:<id>` holders belong to (security review of cmux#52931, item 1).
 *
 * A laptop names its own device id (a random id its daemon keeps in its home), not its install id, so the store
 * cannot derive one from the other without changing what today's laptops send. It binds them instead: the first
 * install that names a device in a chat claims that device there, and from then on another install of the same
 * owner that names it is refused `auto.wrong_device`. So a second laptop, or any other install of the owner, can no
 * longer fence, renew, release or write as a laptop it is not. One install may name several devices (a daemon whose
 * home was reset gets a new id). The binding lives with the chat, so it goes when the chat's object does.
 *
 * An owner caller with no holding install (`install: null`, a phone or a browser session; callers.ts) names no
 * device at all: `auto.not_a_laptop`. A machine is held to its own `vm:<machine>` holder by lease.ts.
 */
const TABLE = `CREATE TABLE IF NOT EXISTS devices (device TEXT PRIMARY KEY, install TEXT NOT NULL)`

export const NOT_A_LAPTOP: AutoRefusal = { ok: false, code: "auto.not_a_laptop", message: "only a laptop's cmux (the Mac app, the CLI or its daemon) holds an Auto chat; this install reads it and sends it messages" }
const WRONG_DEVICE: AutoRefusal = { ok: false, code: "auto.wrong_device", message: "another of your installs holds this chat as that device; write as your own device id" }

/** Null when `by` may write as `holder` in this chat, which then binds it to `by`'s install if no install has it. */
export const claimDevice = (sql: SqlStorage, by: AutoCaller, holder: string): AutoRefusal | null => {
  if (by.kind !== "owner" || !isDevice(holder)) return null
  if (!by.install) return NOT_A_LAPTOP
  sql.exec(TABLE)
  const row = sql.exec(`SELECT install FROM devices WHERE device = ?`, holder).toArray()[0] as { install: string } | undefined
  if (row) return row.install === by.install ? null : WRONG_DEVICE
  sql.exec(`INSERT INTO devices (device, install) VALUES (?, ?)`, holder, by.install)
  return null
}
