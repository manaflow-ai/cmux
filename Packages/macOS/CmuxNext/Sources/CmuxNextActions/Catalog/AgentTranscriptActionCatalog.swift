// Catalog rows for stepping an agent chat's transcript from prompt to prompt. Titles live in
// ActionCatalog.xcstrings. The app binds them by AgentTranscriptStep (CmuxNextAgentPane), which sends
// each to the page as its own command.

nonisolated enum AgentTranscriptActionCatalog: ActionCatalogGroup {
    static func descriptors() -> [ActionDescriptor] {
        [
            // Previous Turn and Next Turn step the agent chat's transcript from prompt to prompt, as the
            // thread minimap's ticks do (cx-f7c). The page handles them; a script reads the transcript instead.
            // Ctrl-Opt arrows: Ctrl-Cmd arrows are the pane-resize aliases (KeyBindingDefaults).
            ActionDescriptor(
                id: "agentPane.previousTurn",
                title: String(localized: "action.agentPane.previousTurn", defaultValue: "Previous Turn", bundle: .module),
                keywords: ["agent", "chat", "turn", "prompt", "message", "previous", "up", "minimap"],
                defaultShortcut: Shortcut(Shortcut.upArrowKey, modifiers: [.control, .option]),
                category: .agents, symbol: "chevron.up", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.nextTurn",
                title: String(localized: "action.agentPane.nextTurn", defaultValue: "Next Turn", bundle: .module),
                keywords: ["agent", "chat", "turn", "prompt", "message", "next", "down", "minimap"],
                defaultShortcut: Shortcut(Shortcut.downArrowKey, modifiers: [.control, .option]),
                category: .agents, symbol: "chevron.down", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            // Previous and Next Bookmarked Prompt step to the prompts bookmarked in the thread minimap or
            // on their rows. Palette only: no default key (a default key needs a design call).
            ActionDescriptor(
                id: "agentPane.previousBookmarkedPrompt",
                title: String(localized: "action.agentPane.previousBookmarkedPrompt", defaultValue: "Previous Bookmarked Prompt", bundle: .module),
                keywords: ["agent", "chat", "bookmark", "bookmarked", "prompt", "turn", "previous", "minimap"],
                category: .agents, symbol: "bookmark", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
            ActionDescriptor(
                id: "agentPane.nextBookmarkedPrompt",
                title: String(localized: "action.agentPane.nextBookmarkedPrompt", defaultValue: "Next Bookmarked Prompt", bundle: .module),
                keywords: ["agent", "chat", "bookmark", "bookmarked", "prompt", "turn", "next", "minimap"],
                category: .agents, symbol: "bookmark.fill", surfaces: [.palette, .keyboard],
                requires: [.agentPaneFocused], targets: [.pane],
                surfacePlan: ActionSurfacePlan(cli: .exempt(.guiOnly), contextMenuExemption: .guiOnly)
            ),
        ]
    }
}
