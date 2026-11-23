import { beforeAll, describe, expect, it } from "vitest"
import vectors from "../../../../cmux-tui/crates/cmux-auto-session/fixtures/conformance.json"
import { differs, replay, type Case } from "./auto-sessions-conformance-support.ts"
import { fakeClock } from "./auto-sessions-support.ts"

/**
 * The Auto mode conformance vectors, replayed against the real routes (src/auto-sessions). The same file is
 * replayed against the Rust fake store, so a rule that changes here and not there fails one of the two.
 */
const cases = vectors.cases as unknown as ReadonlyArray<Case>

describe("auto sessions: the conformance vectors", () => {
  beforeAll(fakeClock)

  it("the matcher reads an object by the keys named, a list item by item, and a missing field as null", () => {
    expect(differs({ a: 1, b: { c: null } }, { a: 1, b: {}, d: 2 })).toBe("")
    expect(differs({ a: [{ k: 1 }] }, { a: [{ k: 1, more: 2 }] })).toBe("")
    expect(differs({ a: [] }, { a: [1] })).not.toBe("")
    expect(differs({ a: 1 }, { a: 2 })).not.toBe("")
    expect(differs({ a: { b: 1 } }, { a: null })).not.toBe("")
  })

  it("names every case once", () => {
    expect(cases.length).toBeGreaterThan(0)
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length)
  })

  for (const [index, c] of cases.entries()) it(c.name, () => replay(c, index))
})
