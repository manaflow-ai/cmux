import { afterAll, beforeAll, describe, expect, it } from "bun:test"
import mysql from "mysql2/promise"
import pg from "pg"
import { copyMobile, verifyMobile } from "../copy-mobile-to-vitess.ts"

/**
 * cmux-mobile-api's Postgres rows into cmux-next-vitess `mobile_*`: the copy makes every table equal,
 * keeps a newer MySQL row (written after the Worker switched) and verify names a changed row.
 */
const pgUrl = process.env.SCRATCH_URL
const myUrl = process.env.MYSQL_URL
const run = pgUrl && myUrl ? describe : describe.skip

const PG_SCHEMA = `
CREATE SCHEMA IF NOT EXISTS mobile_copy_test;
SET search_path = mobile_copy_test;
DROP TABLE IF EXISTS devices, push_tokens, team_prefs;
CREATE TABLE devices (device_id uuid PRIMARY KEY, owner_user_id text NOT NULL, team_id text NOT NULL, kind text NOT NULL, name text NOT NULL,
  wg_public_key text, machine_id text, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(), last_seen_at timestamptz);
CREATE TABLE push_tokens (device_id uuid PRIMARY KEY, owner_user_id text NOT NULL, token text NOT NULL, environment text NOT NULL, topic text NOT NULL,
  kinds text NOT NULL, muted_macs text, previews boolean, updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE team_prefs (user_id text NOT NULL, team_id text NOT NULL, color text, emoji text, transparent boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, team_id));
`

run("copy cmux-mobile-api Postgres rows into Vitess", () => {
  const pgc = new pg.Client({ connectionString: pgUrl })
  let my: mysql.Connection
  beforeAll(async () => {
    await pgc.connect()
    await pgc.query(PG_SCHEMA)
    await pgc.query("SET TIME ZONE 'UTC'")
    my = await mysql.createConnection({ uri: myUrl!, timezone: "Z", dateStrings: true })
    await my.query("SET time_zone = '+00:00'")
    for (const t of ["mobile_devices", "mobile_push_tokens", "mobile_team_prefs"]) await my.query(`DELETE FROM ${t}`)
    await pgc.query(`INSERT INTO devices (device_id, owner_user_id, team_id, kind, name, wg_public_key, machine_id, created_at, updated_at, last_seen_at) VALUES
      ('AAAAAAAA-0000-4000-8000-000000000001', 'u1', 't1', 'mac', 'Studio ✨', 'wg', 'm1', '2026-10-01 10:00:00.123456+00', '2026-10-02 10:00:00.5+00', NULL),
      ('aaaaaaaa-0000-4000-8000-000000000002', 'p:u2', 't2', 'phone', 'iPhone', NULL, NULL, '2026-10-01 10:00:00+00', '2026-10-01 10:00:00+00', '2026-10-03 01:02:03+00')`)
    await pgc.query(`INSERT INTO push_tokens VALUES ('aaaaaaaa-0000-4000-8000-000000000002', 'p:u2', 'tok', 'production', 'dev.cmux.mobile.prod', 'question,chief', NULL, NULL, '2026-10-01 10:00:00+00')`)
    await pgc.query(`INSERT INTO team_prefs VALUES ('u1', 't1', '#fff', '🦊', true, '2026-10-01 10:00:00+00')`)
  })
  afterAll(async () => {
    await pgc.query("DROP SCHEMA mobile_copy_test CASCADE")
    await pgc.end()
    await my.end()
  })

  it("copies every row and verifies equal", async () => {
    expect(await copyMobile(pgc, my)).toEqual({ mobile_devices: 2, mobile_push_tokens: 1, mobile_team_prefs: 1 })
    const report = await verifyMobile(pgc, my)
    expect(report.map((r) => [r.table, r.equal, r.pgCount, r.mysqlCount])).toEqual([
      ["mobile_devices", true, 2, 2],
      ["mobile_push_tokens", true, 1, 1],
      ["mobile_team_prefs", true, 1, 1]
    ])
    const [[d]] = (await my.query("SELECT device_id, name, created_at FROM mobile_devices WHERE owner_user_id = 'u1'")) as unknown as [[{ device_id: string; name: string; created_at: string }]]
    expect(d).toEqual({ device_id: "aaaaaaaa-0000-4000-8000-000000000001", name: "Studio ✨", created_at: "2026-10-01 10:00:00.123" })
  })

  it("keeps a newer MySQL row on a second copy, and verify names it", async () => {
    await my.query("UPDATE mobile_team_prefs SET color = '#000', updated_at = '2026-10-29 00:00:00.000' WHERE user_id = 'u1'")
    await pgc.query("UPDATE devices SET name = 'Renamed', updated_at = '2026-10-04 00:00:00+00' WHERE owner_user_id = 'u1'")
    await copyMobile(pgc, my)
    const [[p]] = (await my.query("SELECT color FROM mobile_team_prefs WHERE user_id = 'u1'")) as unknown as [[{ color: string }]]
    expect(p.color).toBe("#000")
    const [[d]] = (await my.query("SELECT name FROM mobile_devices WHERE owner_user_id = 'u1'")) as unknown as [[{ name: string }]]
    expect(d.name).toBe("Renamed")
    const prefs = (await verifyMobile(pgc, my)).find((r) => r.table === "mobile_team_prefs")!
    expect(prefs.equal).toBe(false)
    expect(prefs.changed).toEqual(["u1\u0000t1"])
  })
})
