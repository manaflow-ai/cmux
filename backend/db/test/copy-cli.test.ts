import { describe, expect, it } from "bun:test"
import { junkMode } from "../copy-pg-to-mysql.ts"

/** copy-pg-to-mysql.ts leaves the junk teams out unless the operator asks for every row (cmuxterm-hq#4767 step 1). */
describe("copy-pg-to-mysql junk-team flag", () => {
  it("excludes junk teams by default and with --exclude-junk-teams", () => {
    expect(junkMode(["bun", "copy-pg-to-mysql.ts", "--branch", "main"])).toBe("exclude")
    expect(junkMode(["bun", "copy-pg-to-mysql.ts", "--branch", "main", "--verify-only"])).toBe("exclude")
    expect(junkMode(["bun", "copy-pg-to-mysql.ts", "--branch", "main", "--exclude-junk-teams"])).toBe("exclude")
  })
  it("includes them only with --include-junk-teams, and refuses both flags", () => {
    expect(junkMode(["--branch", "staging", "--include-junk-teams"])).toBe("include")
    expect(() => junkMode(["--include-junk-teams", "--exclude-junk-teams"])).toThrow("exclusive")
  })
})
