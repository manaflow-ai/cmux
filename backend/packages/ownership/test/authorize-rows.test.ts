import { DatabaseSync } from "node:sqlite"
import { describe, expect, it } from "vitest"
import { OwnerEngine } from "../src/engine.ts"
import type { Domain } from "../src/types.ts"
import { sqliteStore } from "./harness.ts"

/** (f) step 1: a row-mode owner authorizes from its rows (members out of the head). */
describe("authorize reads rows", () => {
  it("passes a read-only row reader to authorize in row mode", () => {
    const domain: Domain<{ n: number }, { user?: string }> = {
      initial: () => ({ n: 0 }),
      authorize: (_s, op, _p, principal, rows) => (op === "join" || rows?.get("member", principal.identity) ? undefined : { code: "auth.forbidden", message: "not a member" }),
      reduce: (s, op, _p, ctx) => ({ ok: true, state: { n: s.n + 1 }, value: null, ...(op === "join" ? { writes: [{ table: "member", op: "upsert" as const, key: ctx.principal.identity, n: null, row: {} }] } : {}) })
    }
    const e = new OwnerEngine(sqliteStore(new DatabaseSync(":memory:")), domain, { stream: "s", rowMode: { snapshotTable: "member", snapshotTail: 0 } })
    const frames: Array<{ t: string; code?: string }> = []
    const run = (who: string, op: string, key: string) => e.submit({ identity: who }, { t: "op", op, params: {}, idempotency_key: key }, (_t, f) => frames.push(f as never))
    run("alice", "post", "a1")
    expect(frames.find((f) => f.t === "reject")).toMatchObject({ code: "auth.forbidden" })
    frames.length = 0
    run("alice", "join", "a2")
    run("alice", "post", "a3")
    expect(frames.filter((f) => f.t === "reject")).toEqual([])
  })
})
