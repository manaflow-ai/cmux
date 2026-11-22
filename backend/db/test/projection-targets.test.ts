import { describe, expect, it, spyOn } from "bun:test"
import { isTransientError } from "../../apps/api/src/projection.ts"
import { projectionTargets, projectRows } from "../../apps/api/src/projection-targets.ts"

const rows = [1, 2, 3].map((id) => ({ id, seq: id, kind: "user.upsert", payload: {} })) as never
const fake = (log: Array<string>, behavior: Record<string, "ok" | "throw" | "dead2">) => {
  const make = (target: string) => async (_env: unknown, _stream: string, rs: ReadonlyArray<{ id: number }>) => {
    log.push(`${target}:${rs.map((r) => r.id).join(",")}`)
    if (behavior[target] === "throw") throw Object.assign(new Error("down"), { code: "ECONNRESET" })
    const dead = behavior[target] === "dead2" ? rs.filter((r) => r.id === 2).map((r) => ({ id: r.id, error: "bad" })) : []
    return { sent: rs.filter((r) => !dead.some((d) => d.id === r.id)).map((r) => r.id), dead }
  }
  return { postgres: make("postgres"), mysql: make("mysql") } as never
}

describe("projection targets during the MySQL move", () => {
  it("defaults to Postgres only; an unknown value is Postgres; the same shadow as primary is none", () => {
    expect(projectionTargets({} as never)).toEqual({ primary: "postgres", shadow: null })
    expect(projectionTargets({ PROJECTION_PRIMARY: "oracle" } as never)).toEqual({ primary: "postgres", shadow: null })
    expect(projectionTargets({ PROJECTION_SHADOW: "postgres" } as never)).toEqual({ primary: "postgres", shadow: null })
    expect(projectionTargets({ PROJECTION_PRIMARY: "mysql", PROJECTION_SHADOW: "postgres" } as never)).toEqual({ primary: "mysql", shadow: "postgres" })
  })

  it("the shadow gets only the rows the primary sent, and its result never changes the batch", async () => {
    const log: Array<string> = []
    const res = await projectRows({ PROJECTION_SHADOW: "mysql" } as never, "s", rows, fake(log, { postgres: "dead2", mysql: "ok" }))
    expect(res).toEqual({ sent: [1, 3], dead: [{ id: 2, error: "bad" }] })
    expect(log).toEqual(["postgres:1,2,3", "mysql:1,3"])
  })

  it("a failing shadow is logged at error level and the primary result stands", async () => {
    const log: Array<string> = []
    const errors = spyOn(console, "error").mockImplementation(() => {})
    try {
      const res = await projectRows({ PROJECTION_SHADOW: "mysql" } as never, "s", rows, fake(log, { postgres: "ok", mysql: "throw" }))
      expect(res.sent).toEqual([1, 2, 3])
      expect(JSON.parse(String(errors.mock.calls[0]?.[0]))).toMatchObject({ event: "projection.shadow.failed", level: "error", target: "mysql", rows: 3, code: "ECONNRESET", errno: null, sql_state: null })
    } finally {
      errors.mockRestore()
    }
  })

  it("a failing primary throws (the channel backs off), and the shadow is not called", async () => {
    const log: Array<string> = []
    await expect(projectRows({ PROJECTION_PRIMARY: "mysql", PROJECTION_SHADOW: "postgres" } as never, "s", rows, fake(log, { mysql: "throw" }))).rejects.toThrow("down")
    expect(log).toEqual(["mysql:1,2,3"])
  })
})

describe("isTransientError for mysql2 errors", () => {
  it("retries deadlocks, lock waits, lost connections and failover; dead-letters bad rows", () => {
    expect(isTransientError({ errno: 1213, sqlState: "40001", code: "ER_LOCK_DEADLOCK" })).toBe(true)
    expect(isTransientError({ errno: 1205, sqlState: "HY000", code: "ER_LOCK_WAIT_TIMEOUT" })).toBe(true)
    expect(isTransientError({ errno: 1290, sqlState: "HY000", code: "ER_OPTION_PREVENTS_STATEMENT" })).toBe(true)
    expect(isTransientError({ code: "PROTOCOL_CONNECTION_LOST", fatal: true })).toBe(true)
    expect(isTransientError({ code: "ETIMEDOUT" })).toBe(true)
    expect(isTransientError({ errno: 1406, sqlState: "22001", code: "ER_DATA_TOO_LONG" })).toBe(false)
    expect(isTransientError({ errno: 1366, sqlState: "HY000", code: "ER_TRUNCATED_WRONG_VALUE_FOR_FIELD" })).toBe(false)
    expect(isTransientError({ errno: 1064, sqlState: "42000", code: "ER_PARSE_ERROR" })).toBe(false)
  })
})
