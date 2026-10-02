import { describe, expect, it } from "bun:test"
import { lintFile } from "../migrate.ts"

const expand = (sql: string) => lintFile("0002_x.sql", `-- phase: expand\n${sql}`)

describe("migration lint (parsed SQL)", () => {
  it("accepts additive expand migrations", async () => {
    expect(await expand("CREATE TABLE t (id text PRIMARY KEY, n int NOT NULL);\nCREATE UNIQUE INDEX t_n ON t (n);")).toEqual([])
    expect(await expand("ALTER TABLE users ADD COLUMN locale text;\nALTER TABLE users ADD COLUMN plan text NOT NULL DEFAULT 'free';\nCREATE INDEX users_locale ON users (locale);")).toEqual([])
    expect(await expand("ALTER TABLE users ADD CONSTRAINT c CHECK (length(email) > 3) NOT VALID;\nUPDATE users SET locale = 'en' WHERE locale IS NULL;")).toEqual([])
  })

  // Each bypass the review found against the earlier regex lint.
  const bypasses: Array<[string, string]> = [
    ["DROP without COLUMN", "ALTER TABLE t DROP c;"],
    ["TYPE without COLUMN", "ALTER TABLE t ALTER c TYPE int;"],
    ["SET NOT NULL without COLUMN", "ALTER TABLE t ALTER c SET NOT NULL;"],
    ["block comment as whitespace", "DROP/**/TABLE t;"],
    ["string that looks like a comment", "SELECT '--'; DROP TABLE t;"],
    ["materialized view", "DROP MATERIALIZED VIEW v;"],
    ["sequence", "DROP SEQUENCE s;"],
    ["drop default", "ALTER TABLE t ALTER c DROP DEFAULT;"],
    ["dynamic SQL", "DO $$ BEGIN EXECUTE 'drop table t'; END $$;"],
    ["NOT NULL without COLUMN keyword", "ALTER TABLE t ADD c text NOT NULL;"],
    ["NOT NULL with a comma in the type", "ALTER TABLE t ADD COLUMN x numeric(10,2) NOT NULL;"],
    ["validated constraint", "ALTER TABLE t ADD CONSTRAINT u UNIQUE (x);"],
    ["unique index on existing table", "CREATE UNIQUE INDEX u ON users (email);"],
    ["rename", "ALTER TABLE t RENAME TO u;"],
    ["truncate", "TRUNCATE t;"],
    ["delete", "DELETE FROM t;"]
  ]
  for (const [what, sql] of bypasses) {
    it(`rejects ${what} in an expand migration`, async () => {
      expect((await expand(sql)).length).toBeGreaterThan(0)
    })
  }

  it("requires a phase header and forbids transaction statements", async () => {
    expect((await lintFile("0002_a.sql", "ALTER TABLE users ADD COLUMN plan text;")).join()).toContain("phase")
    expect((await expand("BEGIN; ALTER TABLE users ADD COLUMN x text; COMMIT;")).join()).toContain("BEGIN")
  })

  it("allows destructive statements only in a contract migration", async () => {
    expect(await lintFile("0003_drop.sql", "-- phase: contract\nALTER TABLE users DROP COLUMN email;")).toEqual([])
  })
})
