import type { Env } from "./env.ts"
import { brainName } from "./chief-brain/brain-do.ts"

/**
 * At-least-once delivery of a cloud-brain Chief's committed wakes from MuxDO to its brain object
 * (P: ChiefBrainDO `<agent>/<conversation>`, O: OpencodeBrainDO `<agent>`). A wake is a row here until
 * the brain's `wake` RPC answers (the brain then holds it durably: P's cb_inbox, O's oc_wake), so an
 * eviction or a deploy reset of the brain while the RPC is in flight no longer loses the message:
 * MuxDO's alarm sends the row again with backoff (1 s doubling to 60 s, at most 12 tries). Both brains
 * take a repeated wake idempotently (keyed by conversation + seq), so a resend never answers twice.
 */
const MAX_TRIES = 12
const MAX_BACKOFF_MS = 60_000
/** A row is due again this long after it was first sent, in case the first RPC dies with its caller. */
const FIRST_RETRY_MS = 30_000

export interface Wake {
  readonly agent: string
  readonly owner: string
  readonly conversation: string
  readonly seq: number
  readonly reason: string
}

const ready = new WeakSet<SqlStorage>()
const table = (sql: SqlStorage) => {
  if (ready.has(sql)) return
  sql.exec(`CREATE TABLE IF NOT EXISTS mux_wake_delivery (conversation TEXT NOT NULL, seq INTEGER NOT NULL, reason TEXT NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, PRIMARY KEY (conversation, seq))`)
  ready.add(sql)
}

/** Records a wake as undelivered (due again after FIRST_RETRY_MS) before the first send. */
export const pendWake = (sql: SqlStorage, w: Wake, now: number): void => {
  table(sql)
  sql.exec(`INSERT INTO mux_wake_delivery (conversation, seq, reason, next_at) VALUES (?, ?, ?, ?) ON CONFLICT DO NOTHING`, w.conversation, w.seq, w.reason, now + FIRST_RETRY_MS)
}

/** The earliest due time of an undelivered wake, or null. */
export const nextDeliveryAt = (sql: SqlStorage): number | null => {
  table(sql)
  const r = sql.exec<{ at: number | null }>(`SELECT MIN(next_at) AS at FROM mux_wake_delivery`).one()
  return r.at === null ? null : Number(r.at)
}

/** One send to the Chief's own brain; true when the brain answered (it holds the wake now). */
export const sendWake = async (env: Env, w: Wake, opencode: boolean): Promise<boolean> => {
  const pi = () => env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(w.agent, w.conversation))).wake(w)
  const o = opencode && env.OPENCODE_BRAIN_DO ? env.OPENCODE_BRAIN_DO.get(env.OPENCODE_BRAIN_DO.idFromName(w.agent)) : undefined
  try {
    const r = o ? await o.wake(w) : await pi()
    // An opencode Chief on a deployment without the container (or switched back to pi) is answered by P.
    if (o && "skipped" in r && (r.skipped === "impl_pi" || r.skipped === "no_container")) await pi()
    return true
  } catch (e) {
    console.warn(JSON.stringify({ msg: "chief_brain.wake_failed", agent: w.agent, conversation: w.conversation, seq: w.seq, error: String(e).slice(0, 200) }))
    return false
  }
}

/** Marks the send's outcome: delivered rows go; a failed one is due again with backoff, or dropped after MAX_TRIES. */
export const settleWake = (sql: SqlStorage, w: Pick<Wake, "conversation" | "seq">, ok: boolean, now: number): void => {
  table(sql)
  if (ok) return void sql.exec(`DELETE FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq)
  const row = sql.exec<{ tries: number }>(`SELECT tries FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq).toArray()[0]
  if (!row) return
  const tries = Number(row.tries) + 1
  if (tries >= MAX_TRIES) {
    console.error(JSON.stringify({ msg: "chief_brain.wake_dropped", conversation: w.conversation, seq: w.seq, tries }))
    return void sql.exec(`DELETE FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq)
  }
  sql.exec(`UPDATE mux_wake_delivery SET tries = ?, next_at = ? WHERE conversation = ? AND seq = ?`, tries, now + Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** (tries - 1)), w.conversation, w.seq)
}

/** The undelivered wakes due now (oldest first, at most `limit`). */
export const dueWakes = (sql: SqlStorage, now: number, limit = 20): Array<{ conversation: string; seq: number; reason: string }> => {
  table(sql)
  return sql
    .exec<{ conversation: string; seq: number; reason: string }>(`SELECT conversation, seq, reason FROM mux_wake_delivery WHERE next_at <= ? ORDER BY next_at LIMIT ?`, now, limit)
    .toArray()
    .map((r) => ({ conversation: String(r.conversation), seq: Number(r.seq), reason: String(r.reason) }))
}
