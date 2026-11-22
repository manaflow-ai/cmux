import { DatabaseSync } from "node:sqlite"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { OwnerEngine, type Domain, type SqlStore } from "@cmux/ownership"
import { drainOutboxChannels } from "../src/owner-outbox.ts"

// The Chief brain warm (owner-outbox.ts, MuxDO wakes only) reaches the Workers runtime; no send here uses it.
vi.mock("../src/mux-wake-delivery.ts", () => ({ warmBrain: async () => {} }))

/**
 * cmux-platform#1172: CloudDO answers a duplicate approval answer during its approved run `in_flight` (not done, retry
 * later) instead of done. Such an item stays queued and is resent, but must not count toward the outbox's dead-letter
 * limit (OUTBOX_MAX_ATTEMPTS, 12): an approved run can take ~25 s. A run that never ends must not keep it queued
 * forever either: past OUTBOX_IN_FLIGHT_MAX_MS (10 min) since its first in_flight reply it counts as an ordinary failure.
 * A target that predates `in_flight` answers as before (not done: a counted failure).
 */
const IN_FLIGHT_MAX_MS = 10 * 60_000

const sqliteStore = (db: DatabaseSync): SqlStore => ({
  exec: <T>(q: string, ...params: Array<unknown>) => db.prepare(q).all(...(params as Array<never>)) as Array<T>,
  transaction: <T>(fn: () => T): T => {
    db.exec("BEGIN")
    try {
      const r = fn()
      db.exec("COMMIT")
      return r
    } catch (e) {
      db.exec("ROLLBACK")
      throw e
    }
  },
})

const answers: Domain<Record<string, never>> = {
  initial: () => ({}),
  reduce: (state) => ({ ok: true, state, value: null, outbox: [{ kind: "integration.approval.answered", entity: "approval:apr_f", payload: { request: "apr_f" }, target: { class: "CloudDO", name: "team_f" } }] }),
}

/** One queued answer; `reply(attempt, ids)` is CloudDO's DeliverResult for each send. Fires the alarm at each due time. */
const world = (reply: (attempt: number, ids: Array<number>) => { done: Array<number>; in_flight?: Array<number> }) => {
  const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), answers, { stream: "feed:user_f", now: () => Date.now() })
  engine.submit({ identity: "session:user_f", kind: "session", user: "user_f" }, { t: "op", op: "feed.answer", params: {}, idempotency_key: "k", origin: "user" }, () => {})
  let sends = 0
  const ns = { idFromName: (n: string) => n, get: () => ({ systemDeliver: async (_e: string, _s: string, items: ReadonlyArray<{ id: number }>) => reply(++sends, items.map((i) => i.id)) }) } as unknown as DurableObjectNamespace
  const queued = () => engine.outboxPending(10).length
  /** One alarm at the channel's next due time; false when nothing is queued. */
  const alarm = async () => {
    const at = engine.outbox.nextDueAt(Date.now())
    if (at === null) return false
    vi.setSystemTime(Math.max(Date.now(), at))
    await drainOutboxChannels(engine, {} as never, () => ns, undefined, undefined, undefined, Infinity)
    return true
  }
  return { engine, alarm, queued, sends: () => sends }
}

describe("an in_flight reply keeps the item queued without counting toward dead letter, up to a bound", () => {
  beforeEach(() => void vi.useFakeTimers({ now: 1_700_000_000_000 }))
  afterEach(() => void vi.useRealTimers())

  it("an item in_flight for 30 alarms is never dead-lettered, then is delivered", async () => {
    const w = world((attempt, ids) => (attempt <= 30 ? { done: [], in_flight: ids } : { done: ids }))
    const started = Date.now()
    for (let i = 0; i < 30; i++) await w.alarm()
    expect(w.sends()).toBe(30)
    expect(w.engine.outbox.deadCount(), "dead-lettered while in_flight").toBe(0)
    expect(w.queued()).toBe(1)
    // A run that ends is redelivered within the bound, and the item leaves the queue.
    expect(Date.now() - started).toBeLessThan(IN_FLIGHT_MAX_MS)
    await w.alarm()
    expect(w.queued()).toBe(0)
    expect(w.engine.outbox.deadCount()).toBe(0)
  })

  it("an item that is always in_flight still dead-letters, after the bound plus the usual limit", async () => {
    const w = world((_attempt, ids) => ({ done: [], in_flight: ids }))
    const started = Date.now()
    for (let i = 0; i < 10_000 && w.engine.outbox.deadCount() === 0; i++) await w.alarm()
    expect(w.engine.outbox.deadCount(), "an always-in_flight item stayed queued").toBe(1)
    expect(Date.now() - started, "dead-lettered before the in_flight bound").toBeGreaterThanOrEqual(IN_FLIGHT_MAX_MS)
    expect(w.queued()).toBe(0)
  })

  it("a target without in_flight (not done) counts each failure as before: dead letter after 12", async () => {
    const w = world(() => ({ done: [] }))
    for (let i = 0; i < 100 && w.engine.outbox.deadCount() === 0; i++) await w.alarm()
    expect(w.sends()).toBe(12)
    expect(w.engine.outbox.deadCount()).toBe(1)
  })
})
