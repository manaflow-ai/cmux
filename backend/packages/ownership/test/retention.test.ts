import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { INTENT_TTL_MS, ProjectionClient, type ClientOut } from "../src/client.ts"
import { LEDGER_RETENTION_MS, OwnerEngine } from "../src/engine.ts"
import type { Domain, OwnerFrame, Principal } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** A counter: every `inc` adds one. */
const counter: Domain<{ n: number }> = {
  initial: () => ({ n: 0 }),
  reduce: (s, op) => (op === "inc" ? { ok: true, state: { n: s.n + 1 }, value: s.n + 1 } : { ok: false, code: "validation.invalid", message: op })
}
const alice: Principal = { identity: "alice" }
const DAY = 24 * 3600_000

describe("ledger retention", () => {
  it("prunes only keys older than the retention; younger keys still replay and stay in snapshots", () => {
    let now = 1_000_000_000_000
    const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), counter, { stream: "c", now: () => now })
    const frames: Array<OwnerFrame> = []
    const submit = (key: string) => engine.submit(alice, { t: "op", op: "inc", params: {}, idempotency_key: key }, (_t, f) => frames.push(f))
    submit("old")
    now += 6 * DAY
    submit("young")
    expect(engine.oldestLedgerAt()).toBe(1_000_000_000_000)
    now += 2 * DAY // "old" is 8 days old, "young" 2 days
    expect(engine.pruneLedger(now - LEDGER_RETENTION_MS)).toBe(1)
    expect(engine.snapshot("alice").decided.map((d) => d.idempotency_key)).toEqual(["young"])
    frames.length = 0
    submit("young")
    expect(frames.find((f) => f.t === "result")).toMatchObject({ replayed: true, value: 2 })
    // The bound in principle 5: a key past the window applies again.
    submit("old")
    expect(frames.filter((f) => f.t === "result").at(-1)).toMatchObject({ replayed: false, value: 3 })
    expect(engine.oldestLedgerAt()).toBe(1_000_000_000_000 + 6 * DAY)
  })

  it("prunes in bounded batches", () => {
    const now = 2_000_000_000_000
    const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), counter, { stream: "c", now: () => now })
    for (let i = 0; i < 25; i++) engine.submit(alice, { t: "op", op: "inc", params: {}, idempotency_key: `k${i}` }, () => undefined)
    expect(engine.pruneLedger(now + 1, 10)).toBe(10)
    expect(engine.pruneLedger(now + 1, 10)).toBe(10)
    expect(engine.pruneLedger(now + 1, 10)).toBe(5)
    expect(engine.oldestLedgerAt()).toBeNull()
  })
})

describe("client intent TTL", () => {
  it("never resends an intent older than INTENT_TTL_MS; it is surfaced as expired", () => {
    const sent: Array<ClientOut> = []
    const client = new ProjectionClient(counter, alice, (o) => sent.push(o))
    let now = 0
    client.clock = () => now
    client.issue("inc", {}, "user", "a")
    now = 1000
    client.issue("inc", {}, "user", "b")
    client.disconnect()
    now = INTENT_TTL_MS + 500 // "a" is past the TTL, "b" is not
    sent.length = 0
    client.reconnect()
    const resent = sent.filter((o) => o.t === "op").map((o) => (o.t === "op" ? o.frame.idempotency_key : ""))
    expect(resent).toEqual(["b"])
    expect(client.expired.map((i) => i.idempotency_key)).toEqual(["a"])
    expect(client.pending.map((i) => i.idempotency_key)).toEqual(["b"])
    const snap = sent.find((o) => o.t === "snapshot.request")
    expect(snap).toEqual({ t: "snapshot.request", pending: ["b", "a"] })
    // A timeout retry of the expired key sends nothing.
    sent.length = 0
    client.retry("a")
    expect(sent).toEqual([])
    // The snapshot answers the query: a decided expired key leaves `expired` (it did apply).
    client.receive({ t: "snapshot", stream: "c", seq: 1, state: { n: 1 }, decided: [{ idempotency_key: "a", ok: true, sequence: 1 }] })
    expect(client.expired).toEqual([])
    expect(client.settledOk.has("a")).toBe(true)
  })
})
