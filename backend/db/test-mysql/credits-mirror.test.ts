import { afterAll, beforeAll, describe, it } from "bun:test"
import mysql from "mysql2/promise"
import { cleanup, creditMirrorCases } from "./credits-cases.ts"

/** The credits mirror's SQL on scratch MySQL 8.4 (credits-cases.ts). */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip

run("credits mirror on MySQL", () => {
  let db: mysql.Connection
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true, supportBigNumbers: true })
    await db.query("SET time_zone = '+00:00'")
  })
  afterAll(async () => {
    await cleanup(db, "team_mirrortest00000001")
    await db.end()
  })
  it("ledger rows go in once, the balance keeps the newest version, the customer is set once", () => creditMirrorCases(db, "team_mirrortest00000001"))
})
