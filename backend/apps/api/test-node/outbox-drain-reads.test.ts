import { DatabaseSync } from "node:sqlite"
import { describe, expect, it, vi } from "vitest"
import { OwnerEngine, type Domain, type SqlStore } from "@cmux/ownership"
import { drainOutboxChannels } from "../src/owner-outbox.ts"

// The Chief brain warm (owner-outbox.ts, MuxDO wakes only) reaches the Workers runtime; no send here uses it.
vi.mock("../src/mux-wake-delivery.ts", () => ({ warmBrain: async () => {} }))

/**
 * An alarm's drain of N due channels reads O(N) outbox rows, not O(N^2) (review F2 on #40370). The per-channel send
 * lock re-checked each channel inside its lock with dueChannels(), which lists every due channel: 4,000 single-row
 * channels read about 8M result rows on one alarm, in every OwnerDO subclass.
 */
const counted = (db: DatabaseSync) => {
  let rows = 0
  const store: SqlStore = {
    exec: <T>(q: string, ...params: Array<unknown>) => {
      const r = db.prepare(q).all(...(params as Array<never>)) as Array<T>
      rows += r.length
      return r
    },
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
  }
  return { store, read: () => rows }
}

/** One op posts one outbox item to its own target object, so N ops make N single-row channels. */
const fanout: Domain<Record<string, never>> = {
  initial: () => ({}),
  reduce: (state, _op, params) => {
    const n = (params as { n: number }).n
    return { ok: true, state, value: null, outbox: [{ kind: "note", entity: `note:${n}`, payload: { n }, target: { class: "TeamDO", name: `team_${n}` } }] }
  },
}

const readsAt = async (n: number) => {
  const db = new DatabaseSync(":memory:")
  const { store, read } = counted(db)
  const engine = new OwnerEngine(store, fanout, { stream: "feed:user_r", now: () => Date.now() })
  for (let i = 0; i < n; i++) engine.submit({ identity: "session:user_r", kind: "session", user: "user_r" }, { t: "op", op: "note", params: { n: i }, idempotency_key: `k${i}`, origin: "user" }, () => {})
  let delivered = 0
  const ns = { idFromName: (x: string) => x, get: () => ({ systemDeliver: async (_e: string, _s: string, items: ReadonlyArray<{ id: number }>) => ((delivered += items.length), { done: items.map((i) => i.id) }) }) } as unknown as DurableObjectNamespace
  const before = read()
  await drainOutboxChannels(engine, {} as never, () => ns, undefined, undefined, undefined, Infinity)
  expect(delivered).toBe(n)
  return read() - before
}

describe("an outbox drain's reads grow linearly with its channels", () => {
  it("reads O(N) rows for N single-row channels (N = 10, 100, 1000)", async () => {
    const at = { 10: await readsAt(10), 100: await readsAt(100), 1000: await readsAt(1000) }
    // A constant number of rows per channel (its pending row, its backoff probe, the sent marks), never one per other channel.
    console.log(`outbox drain rows read: ${JSON.stringify(at)}`)
    for (const [n, reads] of Object.entries(at)) expect(reads / Number(n), `rows read per channel at N = ${n}: ${JSON.stringify(at)}`).toBeLessThanOrEqual(10)
    expect(at[1000] / at[10]).toBeLessThan(150)
  })
})
