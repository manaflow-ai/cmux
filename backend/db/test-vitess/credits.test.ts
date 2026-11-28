import { afterAll, beforeAll, describe, it } from "bun:test"
import mysql from "mysql2/promise"
import { cleanup, creditMirrorCases } from "../test-mysql/credits-cases.ts"

/** The credits mirror's SQL on the PlanetScale Vitess development branch, on a test-only team id that is deleted afterwards. */
const url = process.env.VITESS_URL
const run = url ? describe : describe.skip

run("credits mirror on Vitess (test-only team)", () => {
  let db: mysql.Connection
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true, supportBigNumbers: true })
    await db.query("SET time_zone = '+00:00'")
  })
  afterAll(async () => {
    await cleanup(db, "team_vsmokecredits00001")
    await db.end()
  })
  it("ledger rows go in once, the balance keeps the newest version, the customer is set once", () => creditMirrorCases(db, "team_vsmokecredits00001"))
})
