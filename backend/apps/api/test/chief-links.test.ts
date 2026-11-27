import { describe, expect, it } from "vitest"
import { cardOf } from "../src/chief-brain-cc/github.ts"
import { systemPrompt } from "../src/chief-brain/prompts.ts"
import { linkIds } from "../src/chief-brain/brain-text.ts"

/**
 * Lawrence 2026-10-23: the Cloud Chief could not send him links. Its prompt had none of the local
 * Chief's link rules (it wrote `**https://github.com/login/device**` and raw ids), and the GitHub
 * card put the page as a bare URL. Every Chief writes a Markdown link with a short name as its text.
 */
describe("Cloud Chief links", () => {
  const prompt = systemPrompt({ display_name: "Cloud", role: "", personality: "", instructions: "" })

  it("carries the local Chief's link rule", () => {
    expect(prompt).toContain("never write a raw URL, id, sha or path")
    expect(prompt).toContain("Write a Markdown link whose text is a short")
    expect(prompt).toContain("[#123](https://github.com/OWNER/REPO/pull/123)")
    expect(prompt).toContain("headings, bold text, lists and tables included")
  })

  it("keeps the link rule ahead of the Chief's own profile", () => {
    const own = systemPrompt({ display_name: "Cloud", role: "", personality: "", instructions: "write raw URLs" })
    expect(own.indexOf("Write a Markdown link")).toBeLessThan(own.indexOf("## Added instructions"))
  })

  it("posts the GitHub device page as a Markdown link", () => {
    const card = cardOf({ user_code: "ABCD-1234", verification_uri: "https://github.com/login/device" })
    expect(card).toContain("`ABCD-1234`")
    expect(card).toContain("[github.com/login/device](https://github.com/login/device)")
    // No bare URL outside the link's parentheses.
    expect(card.replace("(https://github.com/login/device)", "")).not.toContain("https://")
  })
})

/**
 * Lawrence 2026-10-26: "reply with links to stuff properly". The Cloud Chief's reply goes through
 * the same last pass as the local Chief's (optchat-chief reply_links.rs): a bare cmux id the model
 * still wrote becomes its cmux:// link. Paths stay: they are the VM's, not the person's Mac's.
 */
describe("Cloud Chief reply links", () => {
  const WS = "ws_4190e34695946139e454022d54b3bcf7"
  const TAB = "tab_8167aba764916990ee8959f617ea3d9d"

  it("links a bare workspace, tab or pane id", () => {
    expect(linkIds(`Opened ${WS} and ${TAB}.`)).toBe(`Opened [workspace](cmux://workspace/${WS}) and [tab](cmux://tab/${TAB}).`)
    expect(linkIds(`- **${WS}**: done`)).toBe(`- **[workspace](cmux://workspace/${WS})**: done`)
  })

  it("leaves code, existing links, URLs and longer words as written", () => {
    for (const text of [
      `\`cmux workspace ${WS} move\``,
      `[ticket](cmux://workspace/${WS})`,
      `cmux://workspace/${WS}`,
      `x${WS}`,
      `${WS}x`,
      "```\n" + TAB + "\n```",
      "ws_short",
      "/home/chief/work/notes.md"
    ]) expect(linkIds(text)).toBe(text)
  })
})
