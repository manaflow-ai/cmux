import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test"
import { beforeEach, describe, expect, it, vi } from "vitest"
import handler from "../src/index.ts"
import { mysqlStore, resetSchemaProbe, StoreSchemaError, type MysqlConn } from "../src/store-mysql.ts"
import { token } from "./helpers.ts"

/**
 * A Worker deployed before its MySQL migration (drizzle-mysql 0004_mobile_build_space adds the `space` columns)
 * must say so: one clear 503 `store.schema_outdated` naming the migration, not a SQL error from every statement.
 */
const MIGRATION = "0004_mobile_build_space"

/** A MySQL connection whose tables lack `space` until `migrated` is set; every other read answers no rows. */
const fakeConn = () => {
  const state = { migrated: false, statements: [] as Array<string> }
  const conn: MysqlConn = {
    async query(sql) {
      state.statements.push(sql)
      if (!state.migrated && /\bspace\b/.test(sql)) throw Object.assign(new Error("Unknown column 'space' in 'field list'"), { errno: 1054, code: "ER_BAD_FIELD_ERROR" })
      return [[], []]
    },
    async end() {}
  }
  return { conn, state }
}

const getDevices = async (conn: MysqlConn) => {
  const e = { ...(env as object), TEST_MYSQL_CONN: conn } as unknown as Parameters<typeof handler.fetch>[1]
  const ctx = createExecutionContext()
  const res = await handler.fetch(new Request("https://api.test/v1/me/devices", { headers: { authorization: `Bearer ${await token("schema-probe")}` } }), e, ctx)
  await waitOnExecutionContext(ctx)
  return { status: res.status, json: (await res.json()) as any }
}

describe("MySQL schema probe", () => {
  beforeEach(() => resetSchemaProbe())

  it("refuses to open a store on a database without the build space columns", async () => {
    const { conn } = fakeConn()
    const err = await mysqlStore(conn).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(StoreSchemaError)
    expect(String((err as Error).message)).toContain(MIGRATION)
  })

  it("answers 503 store.schema_outdated, logs it once, and recovers once the migration is applied", async () => {
    const log = vi.spyOn(console, "log")
    const { conn, state } = fakeConn()
    for (let i = 0; i < 3; i++) {
      const r = await getDevices(conn)
      expect(r.status).toBe(503)
      expect(r.json.error.code).toBe("store.schema_outdated")
      expect(r.json.error.message).toContain(MIGRATION)
    }
    expect(log.mock.calls.filter((c) => String(c[0]).includes("store.schema_outdated"))).toHaveLength(1)
    // No route statement ran on the outdated schema: only the probe.
    expect(state.statements.filter((s) => !/^SET time_zone|LIMIT 0$/.test(s))).toEqual([])

    state.migrated = true
    const ok = await getDevices(conn)
    expect(ok.status).toBe(200)
    expect(ok.json.devices).toEqual([])
    // Once the probe passed, a later store skips it.
    const before = state.statements.length
    await getDevices(conn)
    expect(state.statements.slice(before).some((s) => /LIMIT 0$/.test(s))).toBe(false)
    log.mockRestore()
  })
})
