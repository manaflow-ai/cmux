import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** DO audit 5.15: a JSON head past the row limit is a typed retryable refusal, not an SQLite error. */
describe("JSON head guard", () => {
  it("refuses a commit whose state would pass 1.5 MB with owner.state_full, and keeps the old state", () => {
    const domain: Domain<{ blobs: Array<string> }, Record<string, never>> = {
      initial: () => ({ blobs: [] }),
      reduce: (s) => ({ ok: true, state: { blobs: [...s.blobs, "é".repeat(300_000)] }, value: s.blobs.length + 1 })
    }
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s" })
    const frames: Array<{ t: string; code?: string; retryable?: boolean }> = []
    for (let i = 0; i < 3; i++) e.submit({ identity: "i" }, { t: "op", op: "o", params: {}, idempotency_key: `k${i}` }, (_t, f) => frames.push(f as never))
    // Two commits of 600 KB (UTF-8) each fit; the third would be 1.8 MB.
    expect(e.currentState.blobs).toHaveLength(2)
    const rejects = frames.filter((f) => f.t === "reject")
    expect(rejects).toEqual([expect.objectContaining({ code: "owner.state_full", retryable: true })])
  })
})
