import { canonicalJson } from "@cmux/ownership"
import { describe, expect, it } from "vitest"
import vectors from "../../../catalog/feed-vectors.json"
import { feedDomain } from "../src/domains/feed.ts"
import { buildVectors, type Vector } from "./feed-vector-cases.ts"
import { run } from "./feed-harness.ts"

/**
 * catalog/feed-vectors.json is the contract every feed owner runs (the Rust
 * local feed server replays the same file). This test replays it against the
 * cloud reducer and checks the file is current (`bun scripts/feed-vectors.ts`).
 */
describe("feed conformance vectors", () => {
  it("are current with the scenarios", () => {
    expect(canonicalJson(vectors)).toBe(canonicalJson(buildVectors()))
  })

  for (const v of vectors as unknown as ReadonlyArray<Vector>) {
    it(`replay: ${v.name}`, () => {
      let state = feedDomain.initial()
      for (const s of v.steps) {
        const r = run(state, s.principal, s.op, s.params, s.now, s.tx, s.origin)
        expect({ op: s.op, tx: s.tx, ok: r.ok, code: r.ok ? undefined : r.code }).toEqual({ op: s.op, tx: s.tx, ok: s.expect.ok, code: s.expect.code })
        if (r.ok) {
          expect(canonicalJson(r.value)).toBe(canonicalJson(s.expect.value))
          expect(r.changed).toBe(s.expect.changed)
          if (r.changed) state = r.state
        }
      }
      expect(canonicalJson(state)).toBe(canonicalJson(v.final_state))
    })
  }
})
