import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// A focused text field or composer gets its own keys (Return and its Command, Shift and Option
/// forms, Esc, ↑) before a default binding without a surface of its own. Leo pressed Cmd-Return to
/// steer in the chat composer and the checklist toggle took the key and refused "no todo items"
/// (2026-10-20); the Home composer and a sidebar field lost it the same way.
@MainActor @Suite struct TextInputKeysYieldTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        registry.bind("toggleChecklistItemComplete", invoke: { _ in })
        return registry
    }()

    static func commandReturn(_ resolved: FocusState.Resolved, editing: Bool) throws -> String {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        var focus = FocusState()
        focus.resolved = resolved
        var facts = KeyFacts()
        facts.pageEditableFocused = editing
        return String(describing: KeyRouter(registry: registry).decide(event, focus: focus, keyWindow: .content, facts: facts))
    }

    @Test func theChatComposerGetsCommandReturn() throws {
        #expect(try Self.commandReturn(.agentPage(pane: "pane_agent", tab: "tab_agent"), editing: true) == "deliver")
    }

    @Test func theHomeComposerGetsCommandReturn() throws {
        #expect(try Self.commandReturn(.conversation(pane: "pane_home", tab: "tab_home"), editing: true) == "deliver")
    }

    @Test func aSidebarFieldGetsCommandReturn() throws {
        #expect(try Self.commandReturn(.sidebarField, editing: false) == "deliver")
    }

    /// With no text input focused the default still runs: the Todo page toggles its item.
    @Test func theTodoPageStillToggles() throws {
        #expect(try Self.commandReturn(.page(pane: "pane_todo", tab: "tab_todo"), editing: false).contains("toggleChecklistItemComplete"))
    }

    /// Every default on a text field's key either is scoped to a surface or steps aside for text input.
    @Test func noUnscopedDefaultTakesATextFieldKey() {
        let input = KeyContext(["textInputFocus": .bool(true), "surfaceKind": .string("home")])
        let taken = RegistryKeyBindings(Self.registry).table.entries.filter { entry in
            entry.source == .default && entry.keys.count == 1 && KeyBindingDefaults.textInputKeys.contains(entry.keys[0])
                && (Self.registry.descriptor(for: entry.command)?.requires ?? []).isEmpty
                && entry.applies(in: input)
        }
        #expect(taken.map(\.command.rawValue).isEmpty)
    }
}
