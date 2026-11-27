import { describe, expect, it } from "bun:test"
import { lintSql, loadMigrations } from "../migrate-mysql.ts"

describe("MySQL migration lint (Vitess rules)", () => {
  it("the committed history passes", () => {
    const migrations = loadMigrations()
    expect(migrations.length).toBeGreaterThan(0)
    expect(migrations.flatMap((m) => lintSql(m.name, m.statements))).toEqual([])
  })
  it("refuses foreign keys, partitions, checks, triggers, keyless tables and drops", () => {
    const bad = [
      "CREATE TABLE a (id int PRIMARY KEY, b int, FOREIGN KEY (b) REFERENCES c(id))",
      "CREATE TABLE a (id int PRIMARY KEY) PARTITION BY HASH (id)",
      "CREATE TABLE a (id int PRIMARY KEY, CHECK (id > 0))",
      "CREATE TRIGGER t BEFORE INSERT ON a FOR EACH ROW SET @x = 1",
      "CREATE TABLE a (id int)",
      "DROP TABLE a"
    ]
    for (const s of bad) expect([s, lintSql("x", [s]).length > 0]).toEqual([s, true])
    expect(lintSql("x", ["CREATE TABLE a (id int NOT NULL, CONSTRAINT a_pkey PRIMARY KEY(id))"])).toEqual([])
  })
})
