import AppKit
@testable import CmuxNextActions
import Testing

/// Decision K1 (dogfood call 2026-10-06): Cmd-K clears the terminal, as in Terminal.app, iTerm2
/// and Ghostty, and is no other default shortcut anywhere (chat search, links, the simulator and
/// the palette's Actions menu moved off it).
@MainActor
@Suite struct CommandKClearsTerminalTests {
    static let commandK = Shortcut("k", modifiers: [.command])

    private func boundRegistry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for entry in registry.entries { registry.bind(entry.id) {} }
        return registry
    }

    @Test func commandKClearsTheFocusedTerminal() {
        let registry = boundRegistry()
        registry.context = [.terminalFocused]
        #expect(registry.keyWinner(Self.commandK)?.command == "terminal.clear")
        #expect(registry.effectiveShortcut(for: "terminal.clear") == Self.commandK)
    }

    @Test func commandKDoesNothingElseInAnyContext() {
        let registry = boundRegistry()
        let contexts: [ActionContext] = [
            [], [.agentPaneFocused], [.markdownFocused], [.simulatorFocused], [.browserFocused], [.textBoxFocused],
            [.diffViewerFocused], [.codeEditorFocused], [.omnibarFocused], [.fileExplorerFocused], [.filePreviewFocused],
            [.rightSidebarFocused], [.paletteOpen], [.agentPaneFocused, .textBoxFocused],
        ]
        for context in contexts {
            registry.context = context
            let winner = registry.keyWinner(Self.commandK)?.command
            #expect(winner == nil, "Cmd-K ran \(winner ?? "") in \(context)")
        }
    }

    /// No default binding, alias or chord starts with Cmd-K except Clear Screen and Scrollback.
    @Test func noOtherDefaultBindingUsesCommandK() {
        let registry = ActionRegistry.standard()
        let entries = RegistryKeyBindings(registry).table.entries.filter { $0.keys.first == Self.commandK }
        #expect(entries.map(\.command) == ["terminal.clear"])
    }
}
