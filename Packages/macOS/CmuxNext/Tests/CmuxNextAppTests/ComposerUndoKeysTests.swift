import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextTestSupport
import Testing

/// Cmd-Z and Shift-Cmd-Z belong to the text being edited: the agent chat's and Chief's composer,
/// a page, a text field (https://github.com/manaflow-ai/cmux/issues/38148). Ghostty's macOS defaults
/// bind `super+z=undo`, which the App folds into its binding table as a `.ghosttyFallback` entry
/// routed to Reopen Last Closed Item (`TerminalHostActionRoute`). With no cmux binding on Cmd-Z,
/// that fallback won in every surface but a terminal and a browser page: Cmd-Z in the composer
/// reopened a closed tab and the page never saw the key, so nothing in the prompt was undone.
@MainActor @Suite(.closesItsWindows) struct ComposerUndoKeysTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        registry.bind("history.reopen", invoke: { _ in })
        // Ghostty's macOS default for Cmd-Z, as the App loads it, and a default on Shift-Cmd-Z.
        KeyBindingLoader(registry).loadGhostty([
            KeyBinding(keys: [Shortcut("z", modifiers: [.command])], command: "history.reopen", source: .ghosttyFallback),
            KeyBinding(keys: [Shortcut("z", modifiers: [.command, .shift])], command: "history.reopen", source: .ghosttyFallback),
        ])
        return registry
    }()

    static func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: 6))
    }

    static func decision(_ event: NSEvent, _ resolved: FocusState.Resolved, facts: KeyFacts = KeyFacts(),
                         registry: ActionRegistry = registry) -> String {
        var focus = FocusState()
        focus.resolved = resolved
        return String(describing: KeyRouter(registry: registry).decide(event, focus: focus, keyWindow: .content, facts: facts))
    }

    static var undo: NSEvent { get throws { try key("z", [.command]) } }
    static var redo: NSEvent { get throws { try key("Z", [.command, .shift]) } }

    /// The agent chat's composer, a Home conversation, Chief's Home page and an internal page get
    /// Undo and Redo themselves.
    @Test(arguments: [
        FocusState.Resolved.agentPage(pane: "pane_chat", tab: "tab_chat"),
        .conversation(pane: "pane_home", tab: "tab_home"),
        .page(pane: "pane_page", tab: "tab_page"),
        .textField,
    ])
    func theComposerGetsUndoAndRedo(_ resolved: FocusState.Resolved) throws {
        #expect(Self.decision(try Self.undo, resolved) == "deliver", "Cmd-Z did not reach \(resolved.kind)")
        #expect(Self.decision(try Self.redo, resolved) == "deliver", "Shift-Cmd-Z did not reach \(resolved.kind)")
    }

    /// Home shown as the window's top page (Chief's chat), with no pane focused.
    @Test func chiefOnTheHomePageGetsUndo() throws {
        let facts = KeyFacts(topPage: "home")
        #expect(Self.decision(try Self.undo, .none, facts: facts) == "deliver")
    }

    /// An editable element in any page has the keyboard (`pageEditableFocused`).
    @Test func anEditableElementGetsUndo() throws {
        let facts = KeyFacts(pageEditableFocused: true)
        #expect(Self.decision(try Self.undo, .browserPage(pane: "pane_web", tab: "tab_web"), facts: facts) == "deliver")
    }

    /// Where nothing is edited, Ghostty's Cmd-Z still reopens the last closed item, as before.
    @Test(arguments: [FocusState.Resolved.sidebar, .emptyPane(pane: "pane_empty")])
    func elsewhereGhosttysUndoStillReopens(_ resolved: FocusState.Resolved) throws {
        #expect(Self.decision(try Self.undo, resolved).contains("history.reopen"))
    }

    /// A Cmd-Z the user bound in their own Ghostty config (`.ghostty`) still wins everywhere.
    @Test func theUsersOwnKeybindStillWins() throws {
        let registry = ActionRegistry.standard()
        registry.bind("history.reopen", invoke: { _ in })
        KeyBindingLoader(registry).loadGhostty([
            KeyBinding(keys: [Shortcut("z", modifiers: [.command])], command: "history.reopen", source: .ghostty),
        ])
        #expect(Self.decision(try Self.undo, .agentPage(pane: "pane_chat", tab: "tab_chat"), registry: registry)
            .contains("history.reopen"))
    }
}
