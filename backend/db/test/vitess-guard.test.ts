import { describe, expect, it } from "bun:test"
import { loadMigrations } from "../migrate-mysql.ts"
import { historyProblems, lintMysqlFile, pendingForPhase, releaseGateProblems, schemaDiff, type SchemaSnapshot } from "../vitess-guard.ts"

// plans/cmux-next/db-migrations-DESIGN.md: the Vitess rails. Expand files only add things the
// deployed code survives; contract files need a written reason; some changes are never allowed.
const expand = (sql: string) => lintMysqlFile("0002_x.sql", `-- phase: expand\n${sql}`)
const contract = (sql: string) => lintMysqlFile("0002_x.sql", `-- phase: contract\n-- contract: the Worker stopped reading it in 1234abcd\n${sql}`)

describe("Vitess migration lint (expand/contract)", () => {
  it("the committed history passes", () => {
    const problems = loadMigrations().flatMap((m) => lintMysqlFile(`${m.name}.sql`, m.text))
    expect(problems).toEqual([])
  })

  it("accepts additive expand migrations", () => {
    expect(expand("CREATE TABLE `t` (`id` varchar(64) NOT NULL, `n` int, CONSTRAINT `t_pk` PRIMARY KEY(`id`), CONSTRAINT `t_n` UNIQUE(`n`));")).toEqual([])
    expect(expand("CREATE TABLE t (id int PRIMARY KEY);\n--> statement-breakpoint\nCREATE UNIQUE INDEX t_id2 ON t (id);")).toEqual([])
    expect(expand("ALTER TABLE `users` ADD `locale` varchar(16);")).toEqual([])
    expect(expand("ALTER TABLE users ADD COLUMN plan varchar(16) NOT NULL DEFAULT 'free', ADD INDEX users_plan (plan);")).toEqual([])
    expect(expand("CREATE INDEX `users_locale` ON `users` (`locale`);")).toEqual([])
    expect(expand("ALTER TABLE `home_message_search` ADD FULLTEXT INDEX `hms_body` (`body`) WITH PARSER ngram;")).toEqual([])
  })

  const needContract: Array<[string, string]> = [
    ["drop column", "ALTER TABLE t DROP COLUMN c;"],
    ["drop without COLUMN", "ALTER TABLE t DROP c;"],
    ["modify type", "ALTER TABLE t MODIFY c bigint;"],
    ["modify without COLUMN", "ALTER TABLE t MODIFY COLUMN c varchar(8) NOT NULL;"],
    ["change to the same name", "ALTER TABLE t CHANGE c c bigint;"],
    ["drop default", "ALTER TABLE t ALTER COLUMN c DROP DEFAULT;"],
    ["drop index", "DROP INDEX i ON t;"],
    ["drop index in ALTER", "ALTER TABLE t DROP INDEX i;"],
    ["unique index on an existing table", "CREATE UNIQUE INDEX u ON users (email);"],
    ["unique key in ALTER", "ALTER TABLE users ADD UNIQUE KEY u (email);"],
    ["unique constraint in ALTER", "ALTER TABLE users ADD CONSTRAINT u UNIQUE (email);"],
    ["NOT NULL without DEFAULT", "ALTER TABLE t ADD COLUMN c int NOT NULL;"],
    ["NOT NULL without COLUMN keyword", "ALTER TABLE t ADD c decimal(10,2) NOT NULL;"],
    ["unique column", "ALTER TABLE t ADD COLUMN c int UNIQUE;"],
    ["auto_increment column", "ALTER TABLE t ADD COLUMN c int AUTO_INCREMENT;"],
    ["generated column", "ALTER TABLE t ADD COLUMN c int AS (a + 1) STORED;"],
    ["a destructive clause after an additive one", "ALTER TABLE t ADD COLUMN x int, DROP COLUMN y;"],
  ]
  for (const [what, sql] of needContract) {
    it(`refuses ${what} in an expand migration`, () => {
      expect(expand(sql).join("\n")).toContain("contract")
    })
    it(`allows ${what} in a contract migration with a reason`, () => {
      expect(contract(sql)).toEqual([])
    })
  }

  const never: Array<[string, string]> = [
    ["drop table", "DROP TABLE t;"],
    ["drop table with a comment between", "DROP/**/TABLE t;"],
    ["drop database", "DROP DATABASE d;"],
    ["truncate", "TRUNCATE TABLE t;"],
    ["rename table", "RENAME TABLE t TO u;"],
    ["rename in ALTER", "ALTER TABLE t RENAME TO u;"],
    ["rename column", "ALTER TABLE t RENAME COLUMN a TO b;"],
    ["change that renames", "ALTER TABLE t CHANGE a b int;"],
    ["drop primary key", "ALTER TABLE t DROP PRIMARY KEY;"],
    ["backfill in a migration", "UPDATE t SET c = 1;"],
    ["insert", "INSERT INTO t (id) VALUES (1);"],
    ["delete", "DELETE FROM t;"],
    ["executable comment", "/*!50000 DROP TABLE t */;"],
    ["drop hidden in a string-looking prefix", "SELECT '--'; DROP TABLE t;"],
    ["foreign key", "ALTER TABLE t ADD CONSTRAINT f FOREIGN KEY (a) REFERENCES u (id);"],
    ["table without a primary key", "CREATE TABLE t (id int);"],
    ["unknown statement", "SET GLOBAL read_only = 1;"],
  ]
  for (const [what, sql] of never) {
    it(`refuses ${what} in any phase`, () => {
      expect(expand(sql).length).toBeGreaterThan(0)
      expect(contract(sql).length).toBeGreaterThan(0)
    })
  }

  it("does not read keywords inside identifiers or strings", () => {
    expect(expand("ALTER TABLE `drop` ADD COLUMN `rename` varchar(32) DEFAULT 'DROP TABLE x';")).toEqual([])
  })

  it("requires a phase header after the grandfathered files", () => {
    expect(lintMysqlFile("0002_x.sql", "ALTER TABLE t ADD COLUMN c int;").join()).toContain("phase")
    // A grandfathered name with other content is not grandfathered.
    expect(lintMysqlFile("0000_baseline.sql", "ALTER TABLE t ADD COLUMN c int;").join()).toContain("phase")
  })

  it("requires a written reason on a contract migration", () => {
    expect(lintMysqlFile("0002_x.sql", "-- phase: contract\nALTER TABLE t DROP COLUMN c;").join()).toContain("reason")
    expect(lintMysqlFile("0002_x.sql", "-- phase: contract\n-- contract: short\nALTER TABLE t DROP COLUMN c;").join()).toContain("reason")
  })

  it("keeps expand changes out of a contract file so they deploy first", () => {
    expect(contract("ALTER TABLE t ADD COLUMN x int;\n--> statement-breakpoint\nALTER TABLE t DROP COLUMN y;").join()).toContain("expand")
  })
})

describe("Vitess migration history (append-only)", () => {
  const base = { "0000_baseline.sql": "a", "0001_credits.sql": "b" }
  it("accepts new files numbered above the base", () => {
    expect(historyProblems(base, { ...base, "0002_x.sql": "c" })).toEqual([])
  })
  it("refuses an edited, removed, reused or lower-numbered file", () => {
    expect(historyProblems(base, { ...base, "0001_credits.sql": "B" }).join()).toContain("changed")
    expect(historyProblems(base, { "0000_baseline.sql": "a" }).join()).toContain("removed")
    expect(historyProblems(base, { ...base, "0001_other.sql": "c" }).length).toBeGreaterThan(0)
  })
  it("refuses an expand and a contract migration in the same push (separate deploys)", () => {
    const head = { ...base, "0002_a.sql": "-- phase: expand\nALTER TABLE t ADD COLUMN x int;", "0003_b.sql": "-- phase: contract\n-- contract: the Worker stopped reading y\nALTER TABLE t DROP COLUMN y;" }
    expect(historyProblems(base, head).join()).toContain("separate")
  })
})

describe("staging-first phases", () => {
  const files = (names: Array<[string, string]>) => names.map(([name, text]) => ({ name, text }))
  const e = "-- phase: expand\nALTER TABLE t ADD COLUMN x int;"
  const c = "-- phase: contract\n-- contract: the Worker stopped reading y\nALTER TABLE t DROP COLUMN y;"
  it("applies the pending expand files before the deploy and stops at the first contract file", () => {
    const pending = files([["0002_a", e], ["0003_b", c], ["0004_c", e]])
    expect(pendingForPhase(pending, "expand").map((m) => m.name)).toEqual(["0002_a"])
    expect(pendingForPhase(pending, "all").map((m) => m.name)).toEqual(["0002_a", "0003_b", "0004_c"])
  })
})

describe("release gate (staging first)", () => {
  const schema: SchemaSnapshot = {
    users: { columns: ["id varchar(64) NO", "locale varchar(16) YES"], indexes: ["PRIMARY unique id"] },
  }
  const migrations = [{ name: "0000_baseline", checksum: "a" }, { name: "0001_credits", checksum: "b" }]
  const history = new Map([["0000_baseline", "a"], ["0001_credits", "b"]])

  it("passes when staging ran every migration and the release branch equals staging", () => {
    expect(releaseGateProblems({ migrations, stagingHistory: history, stagingSchema: schema, releaseSchema: schema })).toEqual([])
  })
  it("refuses a migration staging has not run, or ran with another checksum", () => {
    expect(releaseGateProblems({ migrations, stagingHistory: new Map([["0000_baseline", "a"]]), stagingSchema: schema, releaseSchema: schema }).join()).toContain("0001_credits")
    expect(releaseGateProblems({ migrations, stagingHistory: new Map([["0000_baseline", "a"], ["0001_credits", "x"]]), stagingSchema: schema, releaseSchema: schema }).join()).toContain("checksum")
  })
  it("refuses staging history this tree lacks", () => {
    expect(releaseGateProblems({ migrations: migrations.slice(0, 1), stagingHistory: history, stagingSchema: schema, releaseSchema: schema }).join()).toContain("0001_credits")
  })
  it("refuses a release branch whose schema differs from staging", () => {
    const release: SchemaSnapshot = { users: { columns: ["id varchar(64) NO"], indexes: ["PRIMARY unique id"] } }
    expect(releaseGateProblems({ migrations, stagingHistory: history, stagingSchema: schema, releaseSchema: release }).join()).toContain("locale")
  })
  it("schemaDiff names missing tables, columns and indexes on each side", () => {
    expect(schemaDiff(schema, {})).toEqual(["table users: only on staging"])
    expect(schemaDiff({}, schema)).toEqual(["table users: only on release"])
  })
})
