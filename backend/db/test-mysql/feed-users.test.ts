import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { listUsersMysql, sweepDeps } from "../../apps/api/src/feed-sweep.ts"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"

/**
 * The feed sweep's user pages on the MySQL projection (the reader binding): ids in order, the limit, the
 * keyset cursor, and no read without PS_MYSQL_RO. Replaces the feed-users half of the retired shadow-read test.
 */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip
const binding = () => {
  const u = new URL(url!)
  return { host: u.hostname, port: Number(u.port || 3306), user: decodeURIComponent(u.username), password: decodeURIComponent(u.password), database: u.pathname.slice(1), tls: u.searchParams.has("ssl") }
}
const IDS = ["user_fu_a", "user_fu_b", "user_fu_c", "user_fu_d", "user_fu_e"]

run("feed sweep user pages on the MySQL projection", () => {
  let db: mysql.Connection
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
    await db.query("SET time_zone = '+00:00'")
    await db.query("DELETE FROM users WHERE id LIKE 'user\\_fu\\_%'")
    for (const id of [...IDS].reverse()) {
      const [sql, args] = projectionStatementMysql("user.upsert", { id, stack_user_id: `st_${id}`, email: `${id}@example.com`, display_name: id, personal_team: `team_${id}` }, `user:${id}`, 1)!
      await db.query(sql, args)
    }
  }, 60_000)
  afterAll(async () => {
    await db.end()
  })

  it("pages every user id in order through the cursor", async () => {
    const list = sweepDeps({ PS_MYSQL_RO: binding() } as never).listUsers
    // Other test files share the table, so the pages start just before this file's ids.
    expect(await list("user_fu", 2)).toEqual(IDS.slice(0, 2))
    expect(await list("user_fu_b", 2)).toEqual(IDS.slice(2, 4))
    expect(await list("user_fu_d", 1)).toEqual(IDS.slice(4))
    expect((await list(null, 10_000)).filter((id) => id.startsWith("user_fu_"))).toEqual(IDS)
  }, 60_000)

  it("reads only through the reader binding", async () => {
    await expect(listUsersMysql({ PS_MYSQL: binding() } as never, null, 2)).rejects.toThrow("PS_MYSQL_RO binding missing")
  })
})
