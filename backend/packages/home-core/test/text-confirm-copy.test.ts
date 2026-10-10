import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"

describe("text confirmation copy", () => {
  it("has every key in all 21 locales with its placeholders", () => {
    const copy = JSON.parse(readFileSync(new URL("../copy/text-confirm-levels.json", import.meta.url), "utf8")) as { strings: Record<string, Record<string, { value: string; state: string }>> }
    const keys = Object.keys(copy.strings)
    expect(keys).toHaveLength(18)
    for (const key of keys) {
      expect(Object.keys(copy.strings[key]!)).toHaveLength(21)
      for (const [locale, entry] of Object.entries(copy.strings[key]!)) {
        expect(entry.value.length).toBeGreaterThan(0)
        expect(entry.state).toBe(locale === "en" || locale === "ja" ? "translated" : "needs_review")
        if (key === "textConfirm.lockedBy") expect(entry.value).toContain("{name}")
        if (key === "textConfirm.lowered.body") expect(entry.value).toMatch(/\{from\}[\s\S]*\{to\}|\{to\}[\s\S]*\{from\}/)
      }
    }
  })
})
