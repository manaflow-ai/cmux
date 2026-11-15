public import CmuxNextActions

// Customize… (`customize.open`, the palette and the app menu): customize cmux by asking with no
// terminal (cmuxterm-hq `plans/cmux-next/customize-by-asking/DESIGN.md`). It runs New Agent
// Chat's own path with one more argument, the draft `/customize `: a new chat where New Agent
// Chat opens one, its composer starting with the command, so the person types the wish and
// presses Return. The chat's `/customize` (webviews `customizeCommand.ts`) asks its agent, which
// changes the real files while the window shows the preview; `/customize apply`, `discard` and
// `rollback` in the same chat run those `cmux customize` verbs. Nothing here implements the flow.

extension ActionID {
    /// Customize…: a new agent chat whose composer starts with ``AgentPaneSeed/customizeDraft``.
    public static let customizeOpen: ActionID = "customize.open"
}

extension AgentPaneSeed {
    /// The composer's first text for Customize…: the chat command the ask goes through. Shown,
    /// never sent by itself.
    public static let customizeDraft = "/customize "
}

extension ActionInvocation {
    /// This invocation as New Agent Chat's for Customize…: the same target and origin, with
    /// ``AgentPaneSeed/customizeDraft`` as the `draft` argument the new chat's seed takes. A caller's
    /// own `draft` (Settings search's "Ask cmux to do this": `/customize WORDS`) is kept.
    public var customizing: ActionInvocation {
        var invocation = self
        if invocation.arguments["draft"]?.stringValue?.isEmpty ?? true {
            invocation.arguments["draft"] = .string(AgentPaneSeed.customizeDraft)
        }
        return invocation
    }
}
