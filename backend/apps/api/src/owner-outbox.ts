import type { OutboxFailure, OwnerEngine } from "@cmux/ownership"
import { groupTargets, type DeliverResult, type TargetItem } from "./do-outbox.ts"
import type { Env } from "./env.ts"
import { isTransientError } from "./projection.ts"
import { projectRows } from "./projection-targets.ts"

/** Dead outbox items are replayed this long after they died (automatic replay tool). */
export const DEAD_REPLAY_MS = 24 * 3600_000

/**
 * Transient (backoff forever) or poison (counts toward dead letter) for a failed outbox delivery.
 * PlanetScale errors are classified by SQLSTATE (isTransientError); a DO target only by the
 * runtime's own `retryable`/`overloaded` flags, never by message text (security review P2).
 */
export const outboxFailure = (channel: string, e: unknown): OutboxFailure => {
  if (channel === "") return isTransientError(e) ? "transient" : "poison"
  const flags = e as { retryable?: unknown; overloaded?: unknown } | null
  if (flags?.retryable === true || flags?.overloaded === true) return "transient"
  if (e instanceof Error && e.message.startsWith("no binding for ")) return "transient"
  return "poison"
}

/**
 * One alarm's outbox work for an owner: each due channel (PlanetScale projections, or one target
 * object) is drained, fails and backs off on its own; dead items older than DEAD_REPLAY_MS replay.
 */
export const drainOutboxChannels = async <S>(
  engine: OwnerEngine<S>,
  env: Env,
  targetNamespace: (className: string) => DurableObjectNamespace | undefined,
  /** The PlanetScale projector (a fake in tests). */
  project: (env: Env, stream: string, rows: Parameters<typeof projectRows>[2]) => ReturnType<typeof projectRows> = projectRows
): Promise<void> => {
    const outbox = engine.outbox
    // Each channel (PlanetScale projections, or one target object) reads, fails and backs off on
    // its own, so a dead target cannot stop projections or healthy targets.
    for (const channel of outbox.dueChannels(Date.now())) {
      // After a failure a target channel sends its head alone, so a poison item is found by itself.
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
          const ns = targetNamespace(batch.class)
          if (!ns) throw new Error(`no binding for ${batch.class}`)
          const stub = ns.get(ns.idFromName(batch.name)) as unknown as { systemDeliver(entity: string, source: string, items: ReadonlyArray<TargetItem>): Promise<DeliverResult> }
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
  // Rows an older build marked sent instead of deleting go away a batch per alarm.
  outbox.pruneSent(1000)
  const replayed = outbox.replayDead(Date.now(), { deadBefore: Date.now() - DEAD_REPLAY_MS })
  if (replayed > 0) console.warn(JSON.stringify({ msg: "outbox dead letters replayed", stream: engine.stream, count: replayed }))
}
