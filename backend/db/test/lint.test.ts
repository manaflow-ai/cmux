import { describe, expect, it } from "bun:test"
import { lintFile } from "../migrate.ts"

describe("migration lint", () => {
  it("accepts an additive expand migration", () => {
    expect(lintFile("0002_add_x.sql", "-- phase: expand\nALTER TABLE users ADD COLUMN locale text;\nCREATE INDEX users_locale ON users (locale);")).toEqual([])
  })
  it("rejects drops, renames and type changes in an expand migration", () => {
    const errors = lintFile("0002_bad.sql", "-- phase: expand\nALTER TABLE users DROP COLUMN email;\nALTER TABLE hosts RENAME TO machines;\nALTER TABLE users ALTER COLUMN email TYPE int;")
    expect(errors.join("\n")).toContain("DROP")
    expect(errors.join("\n")).toContain("RENAME")
    expect(errors.join("\n")).toContain("TYPE")
  })
  it("rejects NOT NULL columns without a default and a missing phase header", () => {
    expect(lintFile("0002_a.sql", "-- phase: expand\nALTER TABLE users ADD COLUMN plan text NOT NULL;").join()).toContain("DEFAULT")
    expect(lintFile("0002_a.sql", "ALTER TABLE users ADD COLUMN plan text;").join()).toContain("phase")
  })
  it("allows destructive statements only in a contract migration", () => {
    expect(lintFile("0003_drop.sql", "-- phase: contract\nALTER TABLE users DROP COLUMN email;")).toEqual([])
  })
})
