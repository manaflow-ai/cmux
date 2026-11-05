import type { OutboxFailure, OwnerEngine } from "@cmux/ownership"
import { groupTargets, type DeliverResult, type TargetItem } from "./do-outbox.ts"
import type { Env } from "./env.ts"
import { isTransientError } from "./projection.ts"
import { projectRows } from "./projection-targets.ts"
import { warmBrain } from "./mux-wake-delivery.ts"
import { deliverSecurityMail, SECURITY_MAIL_CLASS } from "./security-mail.ts"

/** Dead outbox items are replayed this long after they died (automatic replay tool). */
export const DEAD_REPLAY_MS = 24 * 3600_000

/**
 * Transient (backoff forever) or poison (counts toward dead letter) for a failed outbox delivery.
 * PlanetScale errors are classified by SQLSTATE (isTransientError); a DO target only by the
 * runtime's own `retryable`/`overloaded` flags, never by message text (security review P2).
 * Security mail (channel `Mail:<user>`) is always poison: its retries are capped.
 */
export const outboxFailure = (channel: string, e: unknown): OutboxFailure => {
  if (channel === "") return isTransientError(e) ? "transient" : "poison"
  if (channel.startsWith(`${SECURITY_MAIL_CLASS}:`)) return "poison"
  const flags = e as { retryable?: unknown; overloaded?: unknown } | null
  if (flags?.retryable === true || flags?.overloaded === true) return "transient"
  // A missing binding is a deploy error, not an outage: counted (dead letter after
  // OUTBOX_MAX_ATTEMPTS, replayed a day later), never retried forever.
  return "poison"
}

/** The class name of a Chief wake queue target (home-core conversation outbox `mux.wake`). */
const MUX_CLASS = "MuxDO"
/** A Chief wake queue channel: a person waits on it. */
export const isWakeChannel = (c: string) => c.startsWith(`${MUX_CLASS}:`)

/**
 * One alarm's outbox work for an owner: each due channel (PlanetScale projections, or one target
 * object) is drained, fails and backs off on its own; dead items older than DEAD_REPLAY_MS replay.
 */
export const drainOutboxChannels = async <S>(
  engine: OwnerEngine<S>,
  env: Env,
  targetNamespace: (className: string) => DurableObjectNamespace | undefined,
  /** The PlanetScale projector (a fake in tests). */
  project: (env: Env, stream: string, rows: Parameters<typeof projectRows>[2]) => ReturnType<typeof projectRows> = projectRows,
  /** The security mail sender (a fake in tests). */
  mail: typeof deliverSecurityMail = deliverSecurityMail,
  /** Only these channels (the commit-time wake path); no prune or replay then. */
  only?: (channel: string) => boolean,
  /** At most this many channels (the commit-time path: a change that touches thousands of objects is the alarm's). */
  maxChannels = Infinity
): Promise<void> => {
    const outbox = engine.outbox
    // Each channel (PlanetScale projections, or one target object) reads, fails and backs off on
    // its own, so a dead target cannot stop projections or healthy targets. A Chief's wake queue
    // (MuxDO) goes first: a person waits on it (staging: the wake waited 1-3 s behind the database
    // projection). Every other channel keeps its order: dueChannels has no ORDER BY, and some targets
    // (automations, integrations) read the projection, so the projection ("") is put first explicitly.
    // (A cross-channel order was never guaranteed: each channel backs off on its own.)
    const due = outbox.dueChannels(Date.now())
    const wake = isWakeChannel
    let sent = 0
    for (const channel of [...due.filter(wake), ...due.filter((c) => c === ""), ...due.filter((c) => c !== "" && !wake(c))]) {
      // After a failure a target channel sends its head alone, so a poison item is found by itself.
      if (only && !only(channel)) continue
      if (++sent > maxChannels) break
      const rows = outbox.pending(channel, channel !== "" && outbox.isolating(channel) ? 1 : 100)
      if (rows.length === 0) continue
      try {
        if (channel === "") {
          const res = await project(env, engine.stream, rows)
          // Only the bad row leaves the queue; the rest of the batch committed (home-scale review P1).
          // Dead first: a later sent row for the same key then supersedes (deletes) the dead one.
          for (const d of res.dead) {
            outbox.deadLetter(d.id, Date.now())
            console.error(JSON.stringify({ msg: "outbox row dead-lettered", stream: engine.stream, channel: "planetscale", dead_letter: d.id, error: d.error }))
          }
          outbox.markSent(res.sent, Date.now())
        } else {
          const batch = groupTargets(rows)[0]!
          outbox.markSent(batch.superseded, Date.now())
          if (batch.class === SECURITY_MAIL_CLASS) {
            const res = await mail(env, batch.items)
            // Not configured, no address, or refused (4xx): retrying cannot help and dead letters
            // replay every day, so these leave the queue with a logged reason (no address logged).
            outbox.markSent([...res.done, ...res.dead], Date.now())
            if (res.dead.length > 0) console.error(JSON.stringify({ msg: "security mail dropped", stream: engine.stream, count: res.dead.length, reason: res.reason ?? "mail.refused" }))
            outbox.succeeded(channel)
            continue
          }
          const ns = targetNamespace(batch.class)
          if (!ns) throw new Error(`no binding for ${batch.class}`)
          const stub = ns.get(ns.idFromName(batch.name)) as unknown as { systemDeliver(entity: string, source: string, items: ReadonlyArray<TargetItem>): Promise<DeliverResult> }
          // The commit-time wake path also starts each woken Chief's brain beside MuxDO's commit (mux-wake-delivery.ts).
          // Not awaited: the wake's delivery never waits on a brain's cold start; one warm per conversation.
          if (only && isWakeChannel(channel)) for (const c of new Set(batch.items.filter((i) => i.op === "mux.wake").map((i) => (i.params as { conversation?: unknown } | null)?.conversation))) void warmBrain(env, batch.name, c)
          const res = await stub.systemDeliver(batch.name, engine.stream, batch.items)
          outbox.markSent(res.done, Date.now())
          if (res.done.length < batch.items.length) throw new Error(`${batch.items.length - res.done.length} items not delivered`)
        }
        outbox.succeeded(channel)
      } catch (e) {
        const dead = outbox.failed(channel, Date.now(), outboxFailure(channel, e))
        console.error(JSON.stringify({ msg: "outbox delivery failed", stream: engine.stream, channel: channel || "planetscale", error: String(e), ...(dead === null ? {} : { dead_letter: dead }) }))
      }
    }
  if (only) return
  // Rows an older build marked sent instead of deleting go away a batch per alarm.
  outbox.pruneSent(1000)
  const replayed = outbox.replayDead(Date.now(), { deadBefore: Date.now() - DEAD_REPLAY_MS })
  if (replayed > 0) console.warn(JSON.stringify({ msg: "outbox dead letters replayed", stream: engine.stream, count: replayed }))
}
