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

  it("the replayer refuses an answer or a refusal that differs from the vectors", async () => {
    const open = { by: "owner", op: "put", id: "chat", body: { auto: true, title: "Fix it", harness: "claude", device: "mac1" } }
    await expect(replay({ name: "another epoch", steps: [{ ...open, expect: { session: { epoch: 2 } } }] }, 9001)).rejects.toThrow()
    await expect(replay({ name: "another code", steps: [open, { by: "owner", op: "snapshot", id: "chat", refuse: { status: 404, code: "not_found" } }] }, 9002)).rejects.toThrow()
    await expect(replay({ name: "no refusal", steps: [{ ...open, refuse: { status: 409, code: "auto.closed" } }] }, 9003)).rejects.toThrow()
    await expect(replay({ name: "a refusal", steps: [{ by: "owner", op: "get", id: "chat", expect: { session: { epoch: 1 } } }] }, 9004)).rejects.toThrow()
  })

  it("names every case once", () => {
    expect(cases.length).toBeGreaterThan(0)
    expect(new Set(cases.map((c) => c.name)).size).toBe(cases.length)
  })

  for (const [index, c] of cases.entries()) it(c.name, () => replay(c, index))
})
