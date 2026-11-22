import { describe, expect, it } from "vitest"
import { chiefListText, findChief, parseTextCommand, parseTextLines, partsText, replyText, textPersonOf, type TextChief } from "../src/address/text-chief.ts"

const chief = (id: string, display_name: string, is_default = false): TextChief => ({ id, display_name, is_default, main_conversation: `conv_${id}` })
const MAIN = chief("agent_main", "Chief", true)
const MUSE = chief("agent_muse", "Muse")
const CODEX = chief("agent_codex", "Codex Lead")
const ALL = [MAIN, MUSE, CODEX]

describe("texting Chief on one shared line", () => {
  it("sends a plain text to the primary Chief", () => {
    expect(parseTextCommand("what's on my calendar", ALL)).toEqual({ kind: "send", chief: MAIN, text: "what's on my calendar", one_off: false })
  })

  it("@name sends one text to another Chief without changing the primary", () => {
    expect(parseTextCommand("@muse draft the launch tweet", ALL)).toEqual({ kind: "send", chief: MUSE, text: "draft the launch tweet", one_off: true })
    expect(parseTextCommand("@Codex Lead: is CI green?", ALL)).toEqual({ kind: "send", chief: CODEX, text: "is CI green?", one_off: true })
    expect(parseTextCommand("@codex, status", ALL)).toEqual({ kind: "send", chief: CODEX, text: "status", one_off: true })
  })

  it("an unknown @word is ordinary text for the primary", () => {
    expect(parseTextCommand("@here lunch?", ALL)).toEqual({ kind: "send", chief: MAIN, text: "@here lunch?", one_off: false })
  })

  it("/primary <name> picks a new primary; /primary alone and /chiefs list", () => {
    expect(parseTextCommand("/primary muse", ALL)).toEqual({ kind: "primary", chief: MUSE })
    expect(parseTextCommand("/chief codex", ALL)).toEqual({ kind: "primary", chief: CODEX })
    expect(parseTextCommand("/primary", ALL)).toEqual({ kind: "list" })
    expect(parseTextCommand("/chiefs", ALL)).toEqual({ kind: "list" })
    expect(parseTextCommand("/primary nobody", ALL)).toEqual({ kind: "unknown_chief", name: "nobody" })
    expect(parseTextCommand("/help", ALL)).toEqual({ kind: "help" })
  })

  it("a dedicated line always talks to its Chief", () => {
    expect(parseTextCommand("/primary muse", ALL, CODEX)).toEqual({ kind: "send", chief: CODEX, text: "/primary muse", one_off: false })
  })

  it("no Chiefs means no send", () => {
    expect(parseTextCommand("hi", [])).toEqual({ kind: "no_chief" })
  })

  it("finds Chiefs by id, exact name or a unique prefix only", () => {
    expect(findChief(ALL, "agent_muse")).toBe(MUSE)
    expect(findChief(ALL, "  CHIEF ")).toBe(MAIN)
    expect(findChief(ALL, "codexlead")).toBe(CODEX)
    expect(findChief([...ALL, chief("agent_m2", "Mule")], "mu")).toBeNull()
  })

  it("lists the Chiefs with the primary marked", () => {
    expect(chiefListText(ALL)).toContain("• Chief (primary)")
    expect(chiefListText(ALL)).toContain("  Muse")
  })

  it("prefixes the Chief's name only when asked, and cuts long replies", () => {
    expect(replyText(" done ", "Muse", true)).toBe("Muse: done")
    expect(replyText("done", "Muse", false)).toBe("done")
    const long = replyText("x".repeat(100), "Muse", true, 50)
    expect(long.length).toBeLessThanOrEqual(50)
    expect(long.endsWith("… (more in cmux)")).toBe(true)
  })

  it("renders message parts as text", () => {
    expect(partsText([{ type: "text", text: "hi" }, { type: "attachment", name: "a.png" }, { type: "work" }])).toBe("hi\n[a.png in cmux]")
  })

  it("reads the line map, keeping the shared line", () => {
    const lines = parseTextLines(JSON.stringify({ "+14155550100": { owner: "user_a", chief: "agent_x" }, bad: {} }), "+14155550199")
    expect(lines).toEqual([
      { number: "+14155550100", owner: "user_a", chief: "agent_x" },
      { number: "+14155550199", owner: null, chief: null }
    ])
    expect(parseTextLines("not json", "+14155550199")).toEqual([{ number: "+14155550199", owner: null, chief: null }])
  })

  it("reads the allowed senders", () => {
    const raw = JSON.stringify({ "+14155550123": "me@example.com" })
    expect(textPersonOf(raw, "+14155550123")).toBe("me@example.com")
    expect(textPersonOf(raw, "+14155550124")).toBeNull()
    expect(textPersonOf("{", "+14155550123")).toBeNull()
  })
})
