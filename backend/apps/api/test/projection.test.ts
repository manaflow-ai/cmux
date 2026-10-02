import { describe, expect, it } from "vitest"
import * as projection from "../src/projection.ts"

/**
 * Postgres text and jsonb reject U+0000. One such row would fail the drain's
 * transaction forever and block every later outbox row of that owner (review MED).
 */
describe("outbox projection statements", () => {
  it("never send U+0000 to Postgres, in text or JSON parameters", () => {
    const statement = (projection as unknown as { projectionStatement?: (kind: string, payload: unknown, stream: string, seq: number) => [string, Array<unknown>] | undefined })
      .projectionStatement
    expect(typeof statement).toBe("function")
    const [, values] = statement!("audit.append", {
      team: "team_1", n: 1, op: "team.policy.update", actor: "user_1", on_behalf_of: null, tx: "t", at: 1,
      summary: "reason with \u0000 nul", detail: { reason: "a\u0000b", nested: ["\u0000"] }, prev_hash: "p", hash: "h"
    }, "team:team_1", 3)!
    for (const v of values) expect(String(v)).not.toContain("\u0000")
    expect(statement!("unknown.kind", {}, "s", 1)).toBeUndefined()
  })

  it("make lone surrogates well-formed, in values and keys (review P2-3)", () => {
    const statement = (projection as unknown as { projectionStatement: (kind: string, payload: unknown, stream: string, seq: number) => [string, Array<unknown>] }).projectionStatement
    const [, values] = statement("audit.append", {
      team: "t", n: 1, op: "x", actor: "u", on_behalf_of: null, tx: "t", at: 1, summary: "bad \ud800 end", detail: { ["k\udc00"]: "v\ud800" }, prev_hash: "p", hash: "h"
    }, "team:t", 1)
    for (const v of values) expect(String(v)).not.toMatch(/\\ud[89ab][0-9a-f]{2}|[\ud800-\udfff]/i)
  })
})
