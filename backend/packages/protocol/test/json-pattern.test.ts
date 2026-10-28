import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { isPattern } from "../src/json-pattern.ts"

// Effect 4.0 stable drops a RegExp constraint from JSON Schema unless the filter supplies
// toJsonSchema; the catalog and the generated clients carry the patterns, so they go through isPattern.
describe("patterns in JSON Schema", () => {
  it("isPattern exports its pattern and still validates", () => {
    const Id = Schema.String.check(isPattern(/^x_[a-z]{2}$/))
    expect(Schema.toJsonSchemaDocument(Id).schema).toEqual({ type: "string", pattern: "^x_[a-z]{2}$" })
    expect(Schema.is(Id)("x_ab")).toBe(true)
    expect(Schema.is(Id)("x_abc")).toBe(false)
  })

  it("no protocol source uses Schema.isPattern directly", () => {
    const dir = fileURLToPath(new URL("../src/", import.meta.url))
    const direct = readdirSync(dir)
      .filter((f) => f.endsWith(".ts") && f !== "json-pattern.ts")
      .filter((f) => readFileSync(dir + f, "utf8").includes("Schema.isPattern("))
    expect(direct).toEqual([])
  })
})
