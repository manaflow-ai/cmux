import type { Env } from "./env.ts"
import { brainName } from "./chief-brain/brain-do.ts"

/**
 * At-least-once delivery of a cloud-brain Chief's committed wakes from MuxDO to its brain object
 * (P: ChiefBrainDO `<agent>/<conversation>`, O: OpencodeBrainDO `<agent>`). A wake is a row here until
 * the brain's `wake` RPC answers (the brain then holds it durably: P's cb_inbox, O's oc_wake), so an
 * eviction or a deploy reset of the brain while the RPC is in flight no longer loses the message:
 * MuxDO's alarm sends the row again with backoff (1 s doubling to 60 s) for up to 6 hours. Both brains
 * take a repeated wake idempotently (keyed by conversation + seq, and a seq at or below the brain's
 * cursor is already answered), so a resend never answers twice. Within one conversation wakes go in
 * seq order: a newer wake waits while an older one is undelivered (a brain's first wake sets its cursor), and
 * goes right after the older is delivered.
 * Each send has a time limit, so one hung brain never holds the alarm (and the outbox drain) for long.
 */
const GIVE_UP_MS = 6 * 3600_000
const MAX_BACKOFF_MS = 60_000
export const SEND_TIMEOUT_MS = 10_000
/** A row is due again this long after it was first sent, in case the first RPC dies with its caller. */
const FIRST_RETRY_MS = 30_000

export interface Wake {
  readonly agent: string
  readonly owner: string
  readonly conversation: string
  readonly seq: number
  readonly reason: string
  /** When MuxDO committed it (ms); absent on a resend from the alarm. */
  readonly at?: number
}

/**
 * The conversation's outbox calls this as it hands a Chief's wake to MuxDO (owner-outbox.ts, commit-time path):
 * the brain object starts (its cold start, ~1 s on staging) and warms its admission reads while MuxDO commits
 * the wake, instead of after it. Best effort; the wake itself still comes from MuxDO.
 */
export const warmBrain = (env: Env, agent: string, conversation: unknown): Promise<unknown> =>
  env.CHIEF_BRAIN_ENABLED === "1" && typeof conversation === "string"
    ? (env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation))) as unknown as { warm(): Promise<unknown> }).warm().catch(() => undefined)
    : Promise.resolve()

const ready = new WeakSet<SqlStorage>()
const table = (sql: SqlStorage) => {
  if (ready.has(sql)) return
  sql.exec(`CREATE TABLE IF NOT EXISTS mux_wake_delivery (conversation TEXT NOT NULL, seq INTEGER NOT NULL, reason TEXT NOT NULL, tries INTEGER NOT NULL DEFAULT 0, next_at INTEGER NOT NULL, first_at INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (conversation, seq))`)
  ready.add(sql)
}

/**
 * Records a wake as undelivered before the first send. Returns false when an older wake of the same
 * conversation is still undelivered: then this one goes after the older, in order (MuxDO sends it as soon as
 * the older is delivered, see nextWaiting; the alarm, if that send fails).
 */
export const pendWake = (sql: SqlStorage, w: Wake, now: number): boolean => {
  table(sql)
  const older = sql.exec<{ at: number }>(`SELECT MIN(next_at) AS at FROM mux_wake_delivery WHERE conversation = ? AND seq < ?`, w.conversation, w.seq).one().at
  sql.exec(`INSERT INTO mux_wake_delivery (conversation, seq, reason, next_at, first_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT DO NOTHING`, w.conversation, w.seq, w.reason, older === null ? now + FIRST_RETRY_MS : Number(older), now)
  return older === null
}

/** The earliest due time of an undelivered wake, or null. */
export const nextDeliveryAt = (sql: SqlStorage): number | null => {
  table(sql)
  const r = sql.exec<{ at: number | null }>(`SELECT MIN(next_at) AS at FROM mux_wake_delivery`).one()
  return r.at === null ? null : Number(r.at)
}

/**
 * Which brain object a wake goes to: P (ChiefBrainDO), O (OpencodeBrainDO, which may hand it back to P) or D
 * (ChiefDurableDO, chief-durable/), from the Chief's brain_impl and what this deployment has (durableOn).
 */
export type BrainRoute = "pi" | "opencode" | "durable"
/** Cloud Chief D runs here: the flag and the binding (plans/cmux-next/cloud-chief-durable-DESIGN.md section 7). */
export const durableOn = (env: Env): boolean => env.CHIEF_DURABLE_ENABLED === "1" && env.CHIEF_DURABLE_DO !== undefined

/** One send to the Chief's own brain; true when the brain answered (it holds the wake now). A skip the
 * brain marks `retry` (brain-turn.ts `skip`: a passing refusal) is not delivered: sent again with backoff. */
export const sendWake = async (env: Env, w: Wake, impl: BrainRoute): Promise<boolean> => {
  const pi = () =>
    impl === "durable" && env.CHIEF_DURABLE_DO
      ? (env.CHIEF_DURABLE_DO.get(env.CHIEF_DURABLE_DO.idFromName(brainName(w.agent, w.conversation))) as unknown as { wake(w: Wake): Promise<unknown> }).wake(w)
      : env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(w.agent, w.conversation))).wake(w)
  const o = impl === "opencode" && env.OPENCODE_BRAIN_DO ? env.OPENCODE_BRAIN_DO.get(env.OPENCODE_BRAIN_DO.idFromName(w.agent)) : undefined
  type Answer = { queued: number } | { skipped: string; retry?: true }
  const limit = (p: Promise<unknown>): Promise<Answer> => {
    let timer: ReturnType<typeof setTimeout> | undefined
    return Promise.race([p as Promise<Answer>, new Promise<never>((_, reject) => (timer = setTimeout(() => reject(new Error("wake send timed out")), SEND_TIMEOUT_MS)))]).finally(() => clearTimeout(timer))
  }
  try {
    const r = o ? await limit(o.wake(w)) : await limit(pi())
    // An opencode Chief on a deployment without the container (or switched back to pi) is answered by P.
    const answer = o && "skipped" in r && (r.skipped === "impl_pi" || r.skipped === "no_container") ? await limit(pi()) : r
    if ("skipped" in answer && answer.retry) {
      console.warn(JSON.stringify({ msg: "chief_brain.wake_retry", agent: w.agent, conversation: w.conversation, seq: w.seq, reason: answer.skipped }))
      return false
    }
    return true
  } catch (e) {
    console.warn(JSON.stringify({ msg: "chief_brain.wake_failed", agent: w.agent, conversation: w.conversation, seq: w.seq, error: String(e).slice(0, 200) }))
    return false
  }
}

/** Marks the send's outcome: delivered rows go; a failed one is due again with backoff, or dropped after GIVE_UP_MS. */
export const settleWake = (sql: SqlStorage, w: Pick<Wake, "conversation" | "seq">, ok: boolean, now: number): void => {
  table(sql)
  if (ok) return void sql.exec(`DELETE FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq)
  const row = sql.exec<{ tries: number; first_at: number }>(`SELECT tries, first_at FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq).toArray()[0]
  if (!row) return
  const tries = Number(row.tries) + 1
  if (now - Number(row.first_at) >= GIVE_UP_MS) {
    console.error(JSON.stringify({ msg: "chief_brain.wake_dropped", conversation: w.conversation, seq: w.seq, tries }))
    return void sql.exec(`DELETE FROM mux_wake_delivery WHERE conversation = ? AND seq = ?`, w.conversation, w.seq)
  }
  const at = now + Math.min(MAX_BACKOFF_MS, 1_000 * 2 ** Math.min(tries - 1, 16))
  // Newer wakes of the conversation wait behind this one (order kept).
  sql.exec(`UPDATE mux_wake_delivery SET tries = ?, next_at = ? WHERE conversation = ? AND seq = ?`, tries, at, w.conversation, w.seq)
  sql.exec(`UPDATE mux_wake_delivery SET next_at = MAX(next_at, ?) WHERE conversation = ? AND seq > ?`, at, w.conversation, w.seq)
}

/**
 * After `w` was delivered: the conversation's next undelivered wake (it waited behind `w`, see pendWake),
 * now due again FIRST_RETRY_MS from `now` (its send starts at once; the alarm resends it only if that send dies).
 * Without this a message that came while an earlier wake's RPC was in flight waited for the alarm (about 30 s).
 */
export const nextWaiting = (sql: SqlStorage, w: Pick<Wake, "conversation" | "seq">, now: number): { conversation: string; seq: number; reason: string; at: number } | null => {
  table(sql)
  const r = sql.exec<{ seq: number; reason: string; first_at: number }>(`SELECT seq, reason, first_at FROM mux_wake_delivery WHERE conversation = ? AND seq > ? ORDER BY seq LIMIT 1`, w.conversation, w.seq).toArray()[0]
  if (!r) return null
  // Every newer row too: the alarm must not send one of them while the chain is still on an older one (order kept).
  sql.exec(`UPDATE mux_wake_delivery SET next_at = MAX(next_at, ?) WHERE conversation = ? AND seq >= ?`, now + FIRST_RETRY_MS, w.conversation, r.seq)
  // `at`: when MuxDO took it (Run.timing mux_at; the brain ignores a value older than 60 s).
  return { conversation: w.conversation, seq: Number(r.seq), reason: String(r.reason), at: Number(r.first_at) }
}

/** The undelivered wakes due now, grouped by conversation in seq order (at most `limit`). */
export const dueWakes = (sql: SqlStorage, now: number, limit = 50): Map<string, Array<{ conversation: string; seq: number; reason: string }>> => {
  table(sql)
  const out = new Map<string, Array<{ conversation: string; seq: number; reason: string }>>()
  for (const r of sql.exec<{ conversation: string; seq: number; reason: string }>(`SELECT conversation, seq, reason FROM mux_wake_delivery WHERE next_at <= ? ORDER BY conversation, seq LIMIT ?`, now, limit).toArray()) {
    const c = String(r.conversation)
    out.set(c, [...(out.get(c) ?? []), { conversation: c, seq: Number(r.seq), reason: String(r.reason) }])
  }
  return out
}
