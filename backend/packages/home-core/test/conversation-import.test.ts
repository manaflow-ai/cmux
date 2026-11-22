import { readFileSync } from "node:fs"
import { describe, expect, it } from "vitest"
import { importCases } from "../conformance/import-cases.ts"

describe("conversation.import corpus", () => {
  const stored = JSON.parse(readFileSync(new URL("../conformance/conversation-import-cases.json", import.meta.url), "utf8")) as { cases: Array<{ name: string; expect: unknown }> }
  const fresh = importCases()
  it("replays to the stored corpus exactly", () => {
    expect(JSON.parse(JSON.stringify(fresh.map((c) => ({ name: c.name, expect: c.expect }))))).toEqual(stored.cases.map((c) => ({ name: c.name, expect: c.expect })))
  })
  it("covers refusals, batches, commit and the opening for normal ops", () => {
    const by = Object.fromEntries(fresh.map((c) => [c.name, c.expect]))
    expect(by["import: normal ops wait for commit"]).toEqual({ ok: false, reject: "importing" })
    expect(by["import: commit opens the conversation and bumps the inbox"]).toMatchObject({ ok: true, head: { state: "active", last_seq: 5, agent_text_streak: 4 } })
    expect(by["import: normal ops run after commit"]).toMatchObject({ ok: true })
  })
})
