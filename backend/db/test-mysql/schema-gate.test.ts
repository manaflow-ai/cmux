import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { loadMigrations } from "../migrate-mysql.ts"
import { releaseGateProblems, schemaSnapshot } from "../vitess-guard.ts"

/** The staging-first gate reads real information_schema rows (db-migrations-DESIGN.md). */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip

run("release gate on a migrated MySQL", () => {
  let conn: mysql.Connection
  beforeAll(async () => {
    conn = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
  })
  afterAll(async () => {
    await conn.query("DROP TABLE IF EXISTS gate_probe")
    await conn.end()
  })

  it("passes against itself and names a table the release branch lacks", async () => {
    const migrations = loadMigrations()
    const [rows] = (await conn.query("SELECT name, checksum FROM schema_migrations")) as unknown as [Array<{ name: string; checksum: string }>]
    const history = new Map(rows.map((r) => [r.name, r.checksum]))
    const before = await schemaSnapshot(conn)
    expect(Object.keys(before)).toContain("users")
    expect(Object.keys(before)).not.toContain("schema_migrations")
    expect(releaseGateProblems({ migrations, stagingHistory: history, stagingSchema: before, releaseSchema: before })).toEqual([])

    await conn.query("CREATE TABLE gate_probe (id int NOT NULL, PRIMARY KEY (id))")
    const after = await schemaSnapshot(conn)
    expect(releaseGateProblems({ migrations, stagingHistory: history, stagingSchema: after, releaseSchema: before })).toEqual(["release branch differs from staging: table gate_probe: only on staging"])
  })
})
