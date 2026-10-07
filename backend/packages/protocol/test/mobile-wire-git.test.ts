import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { decodeGitDiffParams, decodeGitDiffResult, decodeGitStatusResult } from "../src/index.ts"

// schemas/mobile-rpc/fixtures/git.json is the shared contract with Swift CmuxMobileWire (c13-viewers.md).
const fixtures = JSON.parse(
  readFileSync(fileURLToPath(new URL("../../../../schemas/mobile-rpc/fixtures/git.json", import.meta.url)), "utf8")
) as { cases: Array<{ message: string; phase?: string; frame: { params?: unknown; value?: unknown } }> }

describe("cmux.mobile/1 git family", () => {
  it("decodes every git fixture with the typed schemas", () => {
    for (const c of fixtures.cases) {
      if (c.message === "git.status" && c.phase === "result") {
        expect(decodeGitStatusResult(c.frame.value)).toEqual(c.frame.value)
      } else if (c.message === "git.diff" && c.phase === "result") {
        expect(decodeGitDiffResult(c.frame.value)).toEqual(c.frame.value)
      } else if (c.message === "git.diff") {
        expect(decodeGitDiffParams(c.frame.params)).toEqual(c.frame.params)
      }
    }
  })

  it("refuses an unknown scope", () => {
    expect(() => decodeGitDiffParams({ path: "/x", scope: "everything" })).toThrow()
  })
})
