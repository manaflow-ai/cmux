import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain, OwnerFrame, Principal } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** `take` succeeds only while `open` is true; otherwise it rejects as retryable (a full queue). */
const gate: Domain<{ open: boolean; n: number }> = {
  initial: () => ({ open: false, n: 0 }),
  reduce: (s, op) => {
    if (op === "open") return { ok: true, state: { ...s, open: true }, value: true }
    if (op === "take") return s.open ? { ok: true, state: { ...s, n: s.n + 1 }, value: s.n + 1 } : { ok: false, code: "queue.full", message: "full", retryable: true }
    return { ok: false, code: "validation.invalid", message: op }
  }
}
const alice: Principal = { identity: "alice" }

describe("retryable rejects", () => {
  it("are not recorded under the key, so a retry with the same key is decided again", () => {
    const engine = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), gate, { stream: "g" })
    const frames: Array<OwnerFrame> = []
    const submit = (op: string, key: string) => engine.submit(alice, { t: "op", op, params: {}, idempotency_key: key }, (_t, f) => frames.push(f))
    submit("take", "k1")
    expect(frames.find((f) => f.t === "reject")).toMatchObject({ code: "queue.full", retryable: true, replayed: false })
    expect(engine.snapshot("alice").decided).toEqual([])
    submit("open", "o1")
    frames.length = 0
    submit("take", "k1")
    expect(frames.find((f) => f.t === "result")).toMatchObject({ value: 1, replayed: false })
    frames.length = 0
    submit("take", "k1")
    expect(frames.find((f) => f.t === "result")).toMatchObject({ value: 1, replayed: true })
    // A non-retryable reject stays decided.
    frames.length = 0
    submit("nope", "k2")
    submit("nope", "k2")
    expect(frames.filter((f) => f.t === "reject").map((f) => (f as { replayed: boolean }).replayed)).toEqual([false, true])
  })
})
