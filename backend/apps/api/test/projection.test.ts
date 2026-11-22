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

/** A fake pg client: a statement whose first value is "poison" fails with `poison`, "down" with `down`. */
const fakeClient = (poison: unknown, down: unknown) => {
  const log: Array<string> = []
  return {
    log,
    query: async (sql: string, values?: Array<unknown>) => {
      if (values?.includes("poison-row")) throw poison
      if (values?.includes("down-row")) throw down
      log.push(sql.trim().split(/\s+/).slice(0, 2).join(" "))
      return { rows: [] }
    }
  }
}
const row = (id: number, text: string) => ({ id, seq: id, kind: "audit.append", entity: `e${id}`, target: null, payload: { team: "team_1", n: id, op: "x", actor: text, on_behalf_of: null, tx: "t", at: 1, summary: "s", detail: {}, prev_hash: "p", hash: "h" } })

describe("projection drain isolates a poison row (review P1)", () => {
  it("sends the good rows, dead-letters only the poison row, and throws on a transient error", async () => {
    const apply = (projection as unknown as { applyProjectionRows?: (client: unknown, stream: string, rows: ReadonlyArray<unknown>) => Promise<{ sent: Array<number>; dead: Array<{ id: number; error: string }> }> }).applyProjectionRows
    const transient = (projection as unknown as { isTransientError?: (e: unknown) => boolean }).isTransientError
    expect(typeof apply).toBe("function")
    expect(transient!(Object.assign(new Error("terminating connection"), { code: "57P01" }))).toBe(true)
    expect(transient!(new Error("Connection terminated unexpectedly"))).toBe(true)
    expect(transient!(Object.assign(new Error("invalid input syntax"), { code: "22P02" }))).toBe(false)
    const client = fakeClient(Object.assign(new Error("invalid input syntax"), { code: "22P02" }), Object.assign(new Error("connection reset"), { code: "08006" }))
    const r = await apply!(client, "team:team_1", [row(1, "a"), row(2, "poison-row"), row(3, "b")])
    expect(r.sent).toEqual([1, 3])
    expect(r.dead.map((d) => d.id)).toEqual([2])
    expect(r.dead[0]!.error).toContain("22P02")
    const down = fakeClient(new Error("x"), Object.assign(new Error("connection reset"), { code: "08006" }))
    await expect(apply!(down, "team:team_1", [row(1, "a"), row(2, "down-row")])).rejects.toThrow(/connection reset/)
  })
})
