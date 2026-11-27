import { afterEach, describe, expect, it, vi } from "vitest"
import { projectionReadMode, shadowRead } from "../src/projection-reads.ts"

/**
 * Shadow reads before the Vitess cutover (plans/cmux-next/vitess-migration-DESIGN.md): with
 * PROJECTION_READS=shadow the caller gets the Postgres answer, the same read runs on MySQL, and
 * each request logs a match or a diff with keys only (never values). A MySQL failure never fails
 * or changes the answer.
 */
describe("projection shadow reads", () => {
  afterEach(() => vi.restoreAllMocks())

  it("reads the mode from PROJECTION_READS; unknown values stay on Postgres", () => {
    expect(projectionReadMode({ PROJECTION_READS: "mysql" })).toBe("mysql")
    expect(projectionReadMode({ PROJECTION_READS: "shadow" })).toBe("shadow")
    expect(projectionReadMode({ PROJECTION_READS: "MySQL" })).toBe("postgres")
    expect(projectionReadMode({})).toBe("postgres")
  })

  it("equal answers log one match event and return the primary answer", async () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {})
    const primary = { rows: ["a/1", "b/2"], body: "secret text" }
    const out = await shadowRead("home.search", async () => primary, async () => ({ rows: ["a/1", "b/2"], body: "secret text" }), (r) => r.rows)
    expect(out).toBe(primary)
    expect(log.mock.calls.map((c) => JSON.parse(String(c[0])))).toEqual([{ event: "projection.read.match", read: "home.search", rows: 2 }])
  })

  it("a different answer logs a diff with keys only and still returns the primary answer", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {})
    const out = await shadowRead("home.search", async () => ({ rows: ["a/1", "b/2"], body: "secret" }), async () => ({ rows: ["a/1", "c/3"], body: "secret" }), (r) => r.rows)
    expect(out.rows).toEqual(["a/1", "b/2"])
    const events = err.mock.calls.map((c) => JSON.parse(String(c[0])))
    expect(events).toEqual([{ event: "projection.read.diff", level: "error", read: "home.search", primary_rows: 2, shadow_rows: 2, only_primary: ["b/2"], only_shadow: ["c/3"], order_differs: false }])
    expect(JSON.stringify(events)).not.toContain("secret")
  })

  it("the same rows in another order is a diff (pagination depends on order)", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {})
    await shadowRead("feed.users", async () => ["u1", "u2"], async () => ["u2", "u1"], (r) => r)
    expect(JSON.parse(String(err.mock.calls[0]?.[0]))).toMatchObject({ event: "projection.read.diff", order_differs: true, only_primary: [], only_shadow: [] })
  })

  it("a failing shadow logs shadow_failed and never changes the answer; a failing primary still throws", async () => {
    const err = vi.spyOn(console, "error").mockImplementation(() => {})
    const out = await shadowRead("feed.users", async () => ["u1"], async () => { throw Object.assign(new Error("Access denied for user x with password y"), { code: "ER_ACCESS_DENIED_ERROR" }) }, (r) => r)
    expect(out).toEqual(["u1"])
    const ev = JSON.parse(String(err.mock.calls[0]?.[0]))
    expect(ev).toEqual({ event: "projection.read.shadow_failed", level: "error", read: "feed.users", code: "ER_ACCESS_DENIED_ERROR" })
    await expect(shadowRead("feed.users", async () => { throw new Error("pg down") }, async () => ["u1"], (r: Array<string>) => r)).rejects.toThrow("pg down")
  })
})
