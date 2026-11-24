import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { TURN_CHECKS, withTurnChecks } from "../src/chief-brain-cc/turn-checks.ts"
import { TURN_CHECKS as OPENCODE_TURN_CHECKS } from "../../../chief-opencode/plugin/chief.ts"

// The one source: the local Chief's chief_kernel::TURN_CHECKS (include_str!). The Cloud Chief's copies must match it.
const source = readFileSync(fileURLToPath(new URL("../../../../Native/OptChat/chief-kernel/src/turn_checks.md", import.meta.url).href), "utf8").trim()

describe("turn checks", () => {
  it("the Cloud Chief's copies are the kernel's turn_checks.md", () => {
    expect(TURN_CHECKS).toBe(source)
    expect(OPENCODE_TURN_CHECKS).toBe(source)
  })

  it("end a hosted turn's prompt, after its messages", () => {
    const prompt = withTurnChecks("[dm · direct · Leo] fix the flaky test")
    expect(prompt.startsWith("[dm · direct · Leo] fix the flaky test\n\n<turn-checks>\n")).toBe(true)
    expect(prompt.endsWith(`${source}\n</turn-checks>`)).toBe(true)
  })
})
