// The actions in an agent chat's header and "..." menu. Each row reaches the
// same page or app operation as the menu; the palette, CLI and MCP all use the
// shared action registry rather than a second effect implementation.

nonisolated enum AgentChatMenuActionCatalog: ActionCatalogGroup {
    private static func chat(_ id: ActionID, _ key: StaticString, _ title: String.LocalizationValue, _ keywords: [String], _ symbol: String,
                             cli: String) -> ActionDescriptor {
        var descriptor = ActionDescriptor(
            id: id,
            title: String(localized: key, defaultValue: title, bundle: .module),
            keywords: keywords,
            category: .agents,
            symbol: symbol,
            surfaces: [.palette],
            requires: [.agentPaneFocused],
            targets: [.pane],
            cliName: cli,
            surfacePlan: ActionSurfacePlan(cli: .offered, contextMenuExemption: .guiOnly)
        )
        // These rows act on the focused chat's own page. Marking them as view actions lets an
        // explicit CLI/MCP pane target run the same operation without a second implementation.
        descriptor.focuses = true
        return descriptor
    }

    static func descriptors() -> [ActionDescriptor] {
        [
            chat("agentPane.toggleDisplaySettings", "action.agentPane.toggleDisplaySettings", "Toggle Text & Width",
                 ["agent", "chat", "display", "text", "width", "appearance", "font", "layout"],
                 "textformat.size", cli: "agent toggle-display-settings"),
            chat("agentPane.replayConversation", "action.agentPane.replayConversation", "Replay Conversation",
                 ["agent", "chat", "conversation", "replay", "history", "recording", "playback"],
                 "arrow.counterclockwise", cli: "agent replay-conversation"),
            chat("agentPane.editInstructions", "action.agentPane.editInstructions", "Edit Project Instructions…",
                 ["agent", "chat", "project", "instructions", "claude.md", "agents.md", "rules", "edit"],
                 "doc.text", cli: "agent edit-instructions"),
            chat("agentPane.addProjectFiles", "action.agentPane.addProjectFiles", "Add Project Files…",
                 ["agent", "chat", "project", "files", "context", "knowledge", "add", "attach"],
                 "folder.badge.plus", cli: "agent add-project-files"),
            chat("agentPane.markUnread", "action.agentPane.markUnread", "Mark Chat Unread",
                 ["agent", "chat", "unread", "notification", "mark", "later"],
                 "circle.fill", cli: "agent mark-unread"),
            chat("agentPane.moveToFloatingChat", "action.agentPane.moveToFloatingChat", "Move Chat to Floating Chat",
                 ["agent", "chat", "floating", "float", "detach", "panel", "window"],
                 "rectangle.inset.filled.and.person.filled" , cli: "agent move-to-floating-chat"),
            // The failed last turn's way on, as its error card's lead button (Continue when the
            // turn did work, Retry when nothing ran; Lawrence 2026-10-29).
            chat("agentPane.continueAfterError", "action.agentPane.continueAfterError", "Continue After Error",
                 ["agent", "chat", "continue", "retry", "try again", "resume", "error", "failed", "rate limit", "capacity"],
                 "arrow.clockwise", cli: "agent continue-after-error"),
            chat("agentPane.toggleMinimap", "action.agentPane.toggleMinimap", "Toggle Thread Minimap",
                 ["agent", "chat", "thread", "minimap", "rail", "prompts", "navigation", "map"],
                 "sidebar.left", cli: "agent toggle-minimap"),
            chat("agentPane.revealCwdInFinder", "action.agentPane.revealCwdInFinder", "Reveal Chat Folder in Finder",
                 ["agent", "chat", "folder", "cwd", "directory", "finder", "reveal", "show"],
                 "folder", cli: "agent reveal-cwd-in-finder"),
            chat("agentPane.openCwdInTerminal", "action.agentPane.openCwdInTerminal", "Open Chat Folder in Terminal",
                 ["agent", "chat", "folder", "cwd", "directory", "terminal", "shell", "open"],
                 "terminal", cli: "agent open-cwd-in-terminal"),
        ]
    }
}
