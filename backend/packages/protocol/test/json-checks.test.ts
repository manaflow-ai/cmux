import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { isMinLength, isPattern } from "../src/json-checks.ts"

// Effect 4.0 stable drops RegExp patterns from JSON Schema and halves a string's minLength; the
// catalog and the generated clients carry both as authored, so protocol sources use json-checks.ts.
describe("JSON Schema checks", () => {
  it("isPattern exports its pattern and still validates", () => {
    const Id = Schema.String.check(isPattern(/^x_[a-z]{2}$/))
    expect(Schema.toJsonSchemaDocument(Id).schema).toEqual({ type: "string", pattern: "^x_[a-z]{2}$" })
    expect(Schema.is(Id)("x_ab")).toBe(true)
    expect(Schema.is(Id)("x_abc")).toBe(false)
  })

  it("isMinLength exports the declared minLength and still validates", () => {
    const Key = Schema.String.check(isMinLength(43), Schema.isMaxLength(43))
    expect(Schema.toJsonSchemaDocument(Key).schema).toEqual({ type: "string", minLength: 43, maxLength: 43 })
    expect(Schema.is(Key)("a".repeat(43))).toBe(true)
    expect(Schema.is(Key)("a".repeat(42))).toBe(false)
  })

  it("no protocol source uses Schema.isPattern, or Schema.isMinLength above 1 on a string", () => {
    const dir = fileURLToPath(new URL("../src/", import.meta.url))
    const direct = readdirSync(dir)
      .filter((f) => f.endsWith(".ts") && f !== "json-checks.ts")
      .flatMap((f) =>
        readFileSync(dir + f, "utf8")
          .split("\n")
          .map((line, i) => [`${f}:${i + 1}`, line] as const)
          .filter(([, line]) => line.includes("Schema.isPattern(") || /Schema\.String\.check\([^)]*Schema\.isMinLength\((?!1\))/.test(line))
          .map(([at]) => at)
      )
    expect(direct).toEqual([])
  })
})
