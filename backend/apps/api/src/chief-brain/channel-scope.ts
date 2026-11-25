/**
 * A channel Chief's tools (plans/cmux-next/chief-channels-DESIGN.md "Tools of a channel Chief").
 *
 * A channel Chief is seen by everyone in its channel, so it never drives its owner's machines: it keeps memory
 * (`zoom`, `date`) and the `chiefs` tool (manageChiefs holds that to `invite` into its own channel), and loses
 * hands, `agent` (subagents work on hands) and `teleport`. Its channel is read from the owner's Chief record when
 * the Chief is turned on (BrainDO.configure), never taken from a request.
 *
 * The cut is twofold: a tool list built while the scope is known leaves the tools out, and every cut tool still in
 * a list built earlier (the brain object can start before the Chief is turned on) refuses when it runs.
 */
export const CHANNEL_TOOLS: ReadonlySet<string> = new Set(["zoom", "date", "chiefs"])

/** The refusal text of a cut tool (the code the model and the tests see). */
export const channelScopeRefusal = (tool: string) => ({
  content: [{ type: "text" as const, text: `chief_channel_scope: a channel Chief has no ${tool} tool; it invites people to its own channel and nothing else` }]
})

type Tool = { readonly name: string; readonly execute: (...args: never[]) => Promise<unknown> }

/** `tools` for a Chief whose channel `channel()` reads (null: not a channel Chief, every tool as it is). */
export const channelScoped = <T extends Tool>(tools: ReadonlyArray<T>, channel: () => string | null): T[] => {
  const scoped = channel() !== null
  return tools
    .filter((t) => !scoped || CHANNEL_TOOLS.has(t.name))
    .map((t) => CHANNEL_TOOLS.has(t.name)
      ? t
      : ({ ...t, execute: (async (...args: never[]) => (channel() !== null ? channelScopeRefusal(t.name) : t.execute(...args))) as T["execute"] }))
}
