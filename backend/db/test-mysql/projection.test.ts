import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import { projectionStatementMysql } from "../../apps/api/src/projection-mysql.ts"

/**
 * Every projection kind against the migrated MySQL (CI: the mysql:8.4 service after
 * "Migrations apply from zero"; locally: scripts/mysql-scratch.sh; or the PlanetScale development
 * branch): a write applies, an older source_seq never moves the row back, a newer one updates it,
 * and deletes respect the same guard. Same cases as test-pg/projection.test.ts.
 */
const url = process.env.MYSQL_URL
const run = url ? describe : describe.skip
const T0 = Date.parse("2026-10-03T00:00:00Z")
const iso = (ms: number) => new Date(ms).toISOString()

interface Case {
  readonly kind: string
  readonly payload: (v: number) => Record<string, unknown>
  readonly read: string
  readonly field: string
  readonly expect: (v: number) => unknown
}
const cases: ReadonlyArray<Case> = [
  {
    kind: "user.upsert",
    payload: (v) => ({ id: "user_p1", stack_user_id: "s1", email: `v${v}@example.com`, display_name: `User ${v}`, personal_team: "team_p1" }),
    read: "SELECT display_name AS f FROM users WHERE id = 'user_p1'",
    field: "f",
    expect: (v) => `User ${v}`
  },
  {
    kind: "install.upsert",
    payload: (v) => ({ id: "inst_p1", user: "user_p1", device: "dev_1", kind: "mac", name: `mac ${v}`, device_name: "d", platform: "macos", thumbprint: "tp", grant: "grant_1", created_at: T0, revoked_at: v > 5 ? T0 + 1000 : null }),
    read: "SELECT name AS f FROM installs WHERE id = 'inst_p1'",
    field: "f",
    expect: (v) => `mac ${v}`
  },
  {
    kind: "team.upsert",
    payload: (v) => ({ id: "team_p1", kind: "personal", display_name: `Team ${v}` }),
    read: "SELECT display_name AS f FROM teams WHERE id = 'team_p1'",
    field: "f",
    expect: (v) => `Team ${v}`
  },
  {
    kind: "membership.upsert",
    payload: (v) => ({ team: "team_p1", user: "user_p1", role: v > 5 ? "admin" : "owner" }),
    read: "SELECT role AS f FROM memberships WHERE team_id = 'team_p1' AND user_id = 'user_p1'",
    field: "f",
    expect: (v) => (v > 5 ? "admin" : "owner")
  },
  {
    kind: "host.upsert",
    payload: (v) => ({ id: "host_p1", team: "team_p1", owner_user: "user_p1", enrolled_by: "user_p1", name: `host ${v}`, platform: "linux", enrolled_at: T0 }),
    read: "SELECT name AS f FROM hosts WHERE id = 'host_p1'",
    field: "f",
    expect: (v) => `host ${v}`
  },
  {
    kind: "automation.upsert",
    payload: (v) => ({ id: "auto_p1", owner: "team_p1", name: `auto ${v}`, enabled: true, version: v, created_by: "user_p1", created_at: T0, updated_at: T0 + v, next_run_at: null }),
    read: "SELECT name AS f FROM automations WHERE id = 'auto_p1'",
    field: "f",
    expect: (v) => `auto ${v}`
  },
  {
    kind: "automation_run.upsert",
    payload: (v) => ({ id: "run_p1", owner: "team_p1", automation: "auto_p1", automation_version: 1, trigger: { type: "manual" }, state: v > 5 ? "done" : "running", step: v, error: null, outcome: null, created_at: T0, started_at: T0, finished_at: v > 5 ? T0 + 9 : null }),
    read: "SELECT state AS f FROM automation_runs WHERE id = 'run_p1'",
    field: "f",
    expect: (v) => (v > 5 ? "done" : "running")
  },
  {
    kind: "connection.upsert",
    payload: (v) => ({ id: "conn_p1", owner: "team_p1", created_by: "user_p1", provider: "github", account: { key: "github:1", name: `acct ${v}` }, scopes_requested: [], scopes_granted: ["repo"], status: "active", sharing: "team", created_at: T0, updated_at: T0 + v }),
    read: "SELECT account_name AS f FROM connections WHERE id = 'conn_p1'",
    field: "f",
    expect: (v) => `acct ${v}`
  },
  {
    kind: "home.conversation.upsert",
    payload: (v) => ({ id: "conv_P1", kind: "group", team_id: null, title: `Title ${v}`, created_by: "user_p1", created_at: iso(T0), last_seq: v, last_at: iso(T0 + v), participant_count: 2, state: "active" }),
    read: "SELECT title AS f FROM home_conversations WHERE id = 'conv_P1'",
    field: "f",
    expect: (v) => `Title ${v}`
  },
  {
    kind: "home.participant.upsert",
    payload: (v) => ({ conversation_id: "conv_P1", participant_id: "user_p1", kind: "human", visible_from_seq: v, joined_at: iso(T0), left_at: null }),
    read: "SELECT visible_from_seq AS f FROM home_participants WHERE conversation_id = 'conv_P1' AND participant_id = 'user_p1'",
    field: "f",
    expect: (v) => v
  },
  {
    kind: "home.invite.upsert",
    payload: (v) => ({ id: "inv_P1", conversation_id: "conv_P1", invited_by: "user_p1", address_id: "addr_P1", channel: "email", status: v > 5 ? "accepted" : "pending", delivery_state: "queued", copy_variant: "A", created_at: iso(T0), expires_at: iso(T0 + 86_400_000), accepted_by: v > 5 ? "user_p2" : null, accepted_at: v > 5 ? iso(T0 + 5) : null }),
    read: "SELECT status AS f FROM home_invites WHERE id = 'inv_P1'",
    field: "f",
    expect: (v) => (v > 5 ? "accepted" : "pending")
  },
  {
    kind: "home.message.upsert",
    payload: (v) => ({ conversation_id: "conv_P1", seq: 1, message_id: "msg_p1", author_id: "user_p1", author_kind: "human", created_at: iso(T0), edited_at: v > 5 ? iso(T0 + 5) : null, body: `body ${v}` }),
    read: "SELECT body AS f FROM home_message_search WHERE conversation_id = 'conv_P1' AND seq = 1",
    field: "f",
    expect: (v) => `body ${v}`
  }
]

run("projection statements on MySQL", () => {
  let db: mysql.Connection
  const apply = async (kind: string, payload: unknown, stream: string, seq: number) => {
    const s = projectionStatementMysql(kind, payload, stream, seq)
    if (!s) throw new Error(`no statement for ${kind}`)
    await db.query(s[0], s[1])
  }
  const one = async (sql: string, field: string) => ((await db.query(sql)) as unknown as [Array<Record<string, unknown>>])[0][0]?.[field]
  beforeAll(async () => {
    db = await mysql.createConnection({ uri: url!, timezone: "Z", dateStrings: true })
    await db.query("SET time_zone = '+00:00'")
    for (const t of ["users", "installs", "teams", "memberships", "hosts", "automations", "automation_runs", "connections", "audit_events", "home_conversations", "home_participants", "home_invites", "home_message_search"]) await db.query(`DELETE FROM ${t}`)
  })
  afterAll(() => db.end())

  for (const c of cases) {
    it(`${c.kind}: applies, ignores an older source_seq, takes a newer one`, async () => {
      await apply(c.kind, c.payload(5), "s:1", 5)
      expect(await one(c.read, c.field)).toBe(c.expect(5))
      await apply(c.kind, c.payload(3), "s:1", 3)
      expect(await one(c.read, c.field)).toBe(c.expect(5))
      await apply(c.kind, c.payload(5), "s:1", 5)
      expect(await one(c.read, c.field)).toBe(c.expect(5))
      await apply(c.kind, c.payload(7), "s:1", 7)
      expect(await one(c.read, c.field)).toBe(c.expect(7))
    })
  }

  it("an older seq leaves every column and source_seq unchanged (the guard is per row, not per column)", async () => {
    await apply("user.upsert", { id: "user_g1", stack_user_id: "sg1", email: "new@example.com", display_name: "New", personal_team: "team_g1" }, "s:g", 10)
    await apply("user.upsert", { id: "user_g1", stack_user_id: "sg1", email: "old@example.com", display_name: "Old", personal_team: "team_old" }, "s:g", 9)
    const [rows] = (await db.query("SELECT email, display_name, personal_team, source_seq FROM users WHERE id = 'user_g1'")) as unknown as [Array<Record<string, unknown>>]
    expect(rows[0]).toMatchObject({ email: "new@example.com", display_name: "New", personal_team: "team_g1", source_seq: 10 })
  })

  it("deletes honor the source_seq guard (automation, host, message, delete_through)", async () => {
    await apply("automation.delete", { id: "auto_p1" }, "s:1", 6)
    expect(await one("SELECT deleted_at IS NULL AS f FROM automations WHERE id = 'auto_p1'", "f")).toBe(1)
    await apply("automation.delete", { id: "auto_p1" }, "s:1", 8)
    expect(await one("SELECT deleted_at IS NULL AS f FROM automations WHERE id = 'auto_p1'", "f")).toBe(0)
    await apply("host.delete", { id: "host_p1" }, "s:1", 8)
    expect(await one("SELECT deleted_at IS NULL AS f FROM hosts WHERE id = 'host_p1'", "f")).toBe(0)
    await apply("home.message.delete", { conversation_id: "conv_P1", seq: 1 }, "s:1", 6)
    expect(await one("SELECT count(*) AS f FROM home_message_search WHERE conversation_id = 'conv_P1'", "f")).toBe(1)
    await apply("home.message.delete", { conversation_id: "conv_P1", seq: 1 }, "s:1", 7)
    expect(await one("SELECT count(*) AS f FROM home_message_search WHERE conversation_id = 'conv_P1'", "f")).toBe(0)
    await apply("home.message.upsert", { conversation_id: "conv_P2", seq: 1, message_id: "m1", author_id: "u", author_kind: "human", created_at: iso(T0), edited_at: null, body: "a" }, "s:2", 1)
    await apply("home.message.upsert", { conversation_id: "conv_P2", seq: 2, message_id: "m2", author_id: "u", author_kind: "human", created_at: iso(T0), edited_at: null, body: "b" }, "s:2", 2)
    await apply("home.message.delete_through", { conversation_id: "conv_P2", seq: 1 }, "s:2", 3)
    expect(await one("SELECT count(*) AS f FROM home_message_search WHERE conversation_id = 'conv_P2'", "f")).toBe(1)
  })

  it("audit.append is append-only (a repeated row is ignored)", async () => {
    const row = { team: "team_p1", n: 1, op: "team.policy.update", actor: "user_p1", on_behalf_of: null, tx: "t", at: T0, summary: "first", detail: {}, prev_hash: "p", hash: "h" }
    await apply("audit.append", row, "team:team_p1", 1)
    await apply("audit.append", { ...row, summary: "second" }, "team:team_p1", 1)
    expect(await one("SELECT summary AS f FROM audit_events WHERE team_id = 'team_p1' AND n = 1", "f")).toBe("first")
  })

  it("home.participant.upsert keeps the stored joined_at when the payload has none", async () => {
    await apply("home.participant.upsert", { conversation_id: "conv_J", participant_id: "user_j", kind: "human", visible_from_seq: 0, joined_at: iso(T0), left_at: null }, "s:j", 1)
    await apply("home.participant.upsert", { conversation_id: "conv_J", participant_id: "user_j", kind: "human", visible_from_seq: 4, left_at: null }, "s:j", 2)
    expect(await one("SELECT joined_at AS f FROM home_participants WHERE conversation_id = 'conv_J'", "f")).toBe("2026-10-03 00:00:00.000")
  })
})
