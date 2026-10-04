import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import { OUTBOX_MAX_ATTEMPTS } from "../src/outbox.ts"
import type { Domain } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

type P = { to?: string; n?: number; write?: boolean }
const domain: Domain<{ n: number }, P> = {
  initial: () => ({ n: 0 }),
  reduce: (s, _op, p) => ({
    ok: true,
    state: { n: s.n + 1 },
    value: null,
    outbox: [p.to ? { kind: "x.op", entity: `k${s.n}`, payload: {}, target: { class: "UserDO", name: p.to } } : { kind: "proj", entity: `e${s.n}`, payload: {} }],
    ...(p.write ? { writes: [{ table: "t", op: "upsert" as const, key: "a", n: p.n ?? 1, row: {} }] } : {})
  })
}
const submit = (e: OwnerEngine<{ n: number }, P>, params: P, key: string) => e.submit({ identity: "i" }, { t: "op", op: "o", params, idempotency_key: key }, () => {})

describe("outbox channels (review fix for E4)", () => {
  it("a failing channel backs off alone and dead-letters its head after the limit", () => {
    let now = 1_000
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", now: () => now })
    submit(e, { to: "user_dead" }, "a")
    submit(e, { to: "user_dead" }, "b")
    submit(e, {}, "c")
    expect(new Set(e.outbox.dueChannels(now))).toEqual(new Set(["UserDO:user_dead", ""]))
    e.outbox.failed("UserDO:user_dead", now)
    expect(e.outbox.dueChannels(now)).toEqual([""])
    expect(e.outbox.nextDueAt(now)).toBe(now)
    e.outbox.markSent(e.outbox.pending("").map((r) => r.id), now)
    expect(e.outbox.nextDueAt(now)).toBeGreaterThan(now)
    let dead: number | null = null
    for (let i = 1; i < OUTBOX_MAX_ATTEMPTS && dead === null; i++) {
      now += 10 * 60_000
      dead = e.outbox.failed("UserDO:user_dead", now)
    }
    expect(dead).not.toBeNull()
    expect(e.outbox.deadCount()).toBe(1)
    expect(e.outbox.pending("UserDO:user_dead").map((r) => r.entity)).toEqual(["k1"])
    expect(e.outbox.dueChannels(now)).toEqual(["UserDO:user_dead"])
  })

  it("transient failures never dead-letter; poison counts only its own failures; dead rows replay (review P1)", () => {
    let now = 1_000
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", now: () => now })
    submit(e, {}, "a")
    submit(e, {}, "b")
    // A long outage: many transient failures, backoff capped at 5 minutes, nothing dead.
    for (let i = 0; i < 3 * OUTBOX_MAX_ATTEMPTS; i++) {
      now += 10 * 60_000
      expect(e.outbox.failed("", now, "transient")).toBeNull()
    }
    expect(e.outbox.deadCount()).toBe(0)
    expect(e.outbox.nextDueAt(now)).toBeLessThanOrEqual(now + 5 * 60_000)
    // After the outage, the channel isolates its head (one row per attempt) until a success.
    expect(e.outbox.isolating("")).toBe(true)
    // One poison failure after the outage does not dead-letter at once.
    expect(e.outbox.failed("", now, "poison")).toBeNull()
    // A single poison row is dead-lettered by id; the others stay pending.
    const [first] = e.outbox.pending("")
    e.outbox.deadLetter(first!.id, now)
    expect(e.outbox.deadCount()).toBe(1)
    expect(e.outbox.pending("").map((r) => r.entity)).toEqual(["e1"])
    e.outbox.succeeded("")
    expect(e.outbox.isolating("")).toBe(false)
    // The replay tool puts dead rows back in the queue, in their original order.
    expect(e.outbox.replayDead(now)).toBe(1)
    expect(e.outbox.deadCount()).toBe(0)
    expect(e.outbox.pending("").map((r) => r.entity)).toEqual(["e0", "e1"])
  })

  it("row writes need rowMode, and row order is unique per table", () => {
    const plain = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s" })
    expect(() => submit(plain, { write: true }, "w")).toThrow(/rowMode/)
    const rows = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), {
      initial: () => ({ n: 0 }),
      reduce: (s, _op, p: { key: string; n: number }) => ({ ok: true, state: { n: s.n + 1 }, value: null, writes: [{ table: "t", op: "upsert", key: p.key, n: p.n, row: {} }] })
    }, { stream: "r", rowMode: { snapshotTable: "t", snapshotTail: 5 } })
    rows.submit({ identity: "i" }, { t: "op", op: "o", params: { key: "a", n: 1 }, idempotency_key: "1" }, () => {})
    expect(() => rows.submit({ identity: "i" }, { t: "op", op: "o", params: { key: "b", n: 1 }, idempotency_key: "2" }, () => {})).toThrow(/already belongs/)
    expect(rows.currentSeq).toBe(1)
  })

  it("event pruning removes only a contiguous prefix, even after the clock steps back", () => {
    const times = [100, 200, 300, 50, 400, 500]
    let i = 0
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", now: () => times[Math.min(i, times.length - 1)]! })
    for (; i < times.length; i++) submit(e, {}, `k${i}`)
    // Seq 4 committed at 50 (clock stepped back). Pruning before 350 deletes seqs 1-4: the cut is the
    // first event at or after 350 (seq 5), so no hole opens and seq 4 is never kept behind a gap.
    expect(e.pruneEvents(350, 0)).toBe(4)
    expect(e.eventsAfter(0).map((x) => x.seq)).toEqual([5, 6])
    expect(e.canReplayFrom(4)).toBe(true)
    expect(e.canReplayFrom(3)).toBe(false)
  })
})
