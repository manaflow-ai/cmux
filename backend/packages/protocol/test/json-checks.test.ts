import { readdirSync, readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"
import { isMinLength, isPattern } from "../src/json-checks.ts"

const protocolSources = (): Record<string, string> => {
  const dir = fileURLToPath(new URL("../src/", import.meta.url))
  return Object.fromEntries(
    readdirSync(dir)
      .filter((f) => f.endsWith(".ts") && f !== "json-checks.ts")
      .map((f) => [f, readFileSync(dir + f, "utf8")])
  )
}

/** Array length bounds, which JSON Schema exports as minItems: Effect keeps those as written. */
const ARRAY_BOUNDS = new Set(["feed.ts Schema.isMinLength(min)", "feed-kinds.ts Schema.isMinLength(min)"])

/** Every Schema.isPattern call, and every Schema.isMinLength call whose bound is not 1, by file:line. */
const directChecks = (sources: Record<string, string>): Array<string> =>
  Object.entries(sources).flatMap(([file, text]) =>
    [...text.matchAll(/Schema\.(isPattern|isMinLength)\(\s*((?:\/(?:\\.|[^/\n])+\/[a-z]*)|[^,)]*?)\s*[,)]/g)]
      .filter((m) => m[1] === "isPattern" || m[2] !== "1")
      .map((m) => ({ at: `${file}:${text.slice(0, m.index).split("\n").length}`, call: `Schema.${m[1]}(${m[2]})` }))
      .filter(({ call }) => !ARRAY_BOUNDS.has(`${file} ${call}`))
      .map(({ at, call }) => `${at} ${call}`)
  )

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

  it("isMinLength refuses a bound Effect would normalize", () => {
    for (const bad of [-1, 2.5, Number.NaN, Number.POSITIVE_INFINITY]) expect(() => isMinLength(bad)).toThrow(RangeError)
  })

  it("no protocol source uses Schema.isPattern, or Schema.isMinLength above 1 outside the array helpers", () => {
    expect(directChecks(protocolSources())).toEqual([])
  })

  it("the guard sees a call after another check and a call split over lines", () => {
    const fixture = [
      "const A = Schema.String.check(Schema.isMaxLength(9), Schema.isMinLength(3))",
      "const B = Schema.String.check(",
      "  Schema.isMinLength(",
      "    43",
      "  )",
      ")",
      "const C = Schema.String.check(Schema.isMinLength(1))",
      "const D = Schema.String.check(Schema.isPattern(/^x$/))"
    ].join("\n")
    expect(directChecks({ "fixture.ts": fixture })).toEqual([
      "fixture.ts:1 Schema.isMinLength(3)",
      "fixture.ts:3 Schema.isMinLength(43)",
      "fixture.ts:8 Schema.isPattern(/^x$/)"
    ])
  })
})
