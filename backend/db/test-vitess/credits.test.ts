import { afterAll, beforeAll, describe, it } from "bun:test"
import mysql from "mysql2/promise"
import { cleanup, creditMirrorCases } from "../test-mysql/credits-cases.ts"

/** The credits mirror's SQL on the PlanetScale Vitess development branch, on a test-only team id that is deleted afterwards. */
const url = process.env.VITESS_URL
const run = url ? describe : describe.skip

/** One generous limit for the shared branch (2026-10-19: the 5 s default timed out every step). */
const LIMIT = 60_000

run("credits mirror on Vitess (test-only team)", () => {
  let db: mysql.Connection
  // A body still running after its timeout: afterAll waits for it, so the cleanup never deletes
  // rows under it (that turned a timeout into a misleading "expected a rejection" failure).
  let running: Promise<unknown> = Promise.resolve()
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true, supportBigNumbers: true })
    await db.query("SET time_zone = '+00:00'")
  }, LIMIT)
  afterAll(async () => {
    await running
    await cleanup(db, "team_vsmokecredits00001")
    await db.end()
  }, LIMIT)
  it("ledger rows go in once, the balance keeps the newest version, the customer is set once", () => {
    const done = creditMirrorCases(db, "team_vsmokecredits00001")
    running = Promise.all([running, done.catch(() => {})])
    return done
  }, LIMIT)
})
