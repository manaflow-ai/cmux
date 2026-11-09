import { describe, expect, it } from "vitest"
import { channelScoped } from "../src/chief-brain/channel-scope.ts"

/**
 * A channel Chief's tools (chief-channels-DESIGN.md "Tools of a channel Chief"): memory and the chiefs tool only. No
 * hands, teleport or agent: a Chief that many people see never drives its owner's machines. The list is cut when
 * the tools are installed, and each cut tool also refuses when it runs, for a list installed before the scope was
 * known (the brain starts before its Chief is turned on as a channel Chief).
 */
const tool = (name: string) => ({ name, execute: async (_args: unknown, _api: unknown) => ({ content: [{ type: "text" as const, text: `${name} ran` }] }) })
const all = ["zoom", "date", "chiefs", "teleport", "agent", "hands"].map(tool)
const text = (r: { content: ReadonlyArray<{ type: string; text?: string }> }) => r.content.map((c) => c.text).join("")

describe("a channel Chief's tools", () => {
  it("lists memory and chiefs only", () => {
    expect(channelScoped(all, () => "conv_launch").map((t) => t.name)).toEqual(["zoom", "date", "chiefs"])
  })

  it("leaves another Chief's tools as they are", async () => {
    const tools = channelScoped(all, () => null)
    expect(tools.map((t) => t.name)).toEqual(["zoom", "date", "chiefs", "teleport", "agent", "hands"])
    expect(text(await tools[3]!.execute({}, {} as never))).toBe("teleport ran")
  })

  it("refuses a tool listed before the scope was known", async () => {
    let channel: string | null = null
    const tools = channelScoped(all, () => channel)
    channel = "conv_launch"
    const hands = tools.find((t) => t.name === "hands")!
    expect(text(await hands.execute({}, {} as never))).toContain("chief_channel_scope")
    expect(text(await tools.find((t) => t.name === "zoom")!.execute({}, {} as never))).toBe("zoom ran")
  })
})
