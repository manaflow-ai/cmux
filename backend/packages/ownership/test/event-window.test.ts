import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** DO audit F-3: event windows are bounded by bytes and count, never below a floor. */
const domain: Domain<{ n: number }, { pad: string }> = { initial: () => ({ n: 0 }), reduce: (s) => ({ ok: true, state: { n: s.n + 1 }, value: null }) }
const run = (e: OwnerEngine<{ n: number }, { pad: string }>, i: number, bytes: number) =>
  e.submit({ identity: "i" }, { t: "op", op: "o", params: { pad: "x".repeat(bytes) }, idempotency_key: `k${i}` }, () => {})

describe("event window", () => {
  it("drops the oldest events past the byte cap, keeping at least the floor", () => {
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", eventWindow: { maxBytes: 50_000, maxEvents: 1_000, floor: 3, retentionMs: 3_600_000 } })
    for (let i = 0; i < 20; i++) run(e, i, 10_000)
    expect(e.eventWindowDue(Date.now())).toBe(true)
    while (e.pruneEventWindow(Date.now()) > 0) {}
    const kept = e.eventsAfter(0)
    expect(kept.length).toBeGreaterThanOrEqual(3)
    expect(kept.length).toBeLessThanOrEqual(5)
    expect(kept.at(-1)!.seq).toBe(20)
    expect(e.eventWindowDue(Date.now())).toBe(false)
    // The floor wins over the byte cap.
    for (let i = 20; i < 24; i++) run(e, i, 60_000)
    while (e.pruneEventWindow(Date.now()) > 0) {}
    expect(e.eventsAfter(0).map((x) => x.seq)).toEqual([22, 23, 24])
  })

  it("drops the oldest events past the count cap", () => {
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", eventWindow: { maxBytes: 1e9, maxEvents: 10, floor: 3, retentionMs: 3_600_000 } })
    for (let i = 0; i < 25; i++) run(e, i, 10)
    while (e.pruneEventWindow(Date.now()) > 0) {}
    expect(e.eventsAfter(0).map((x) => x.seq)).toEqual([16, 17, 18, 19, 20, 21, 22, 23, 24, 25])
  })
})
