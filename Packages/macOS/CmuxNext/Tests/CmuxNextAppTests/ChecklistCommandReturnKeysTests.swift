import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import Testing

/// Cmd-Return is the checklist toggle's default key, but an agent chat steers its running turn
/// with it (Composer.tsx) and web pages submit with it. Before, the toggle took the key in the
/// agent composer and refused "this workspace has no todo items" instead of steering.
@MainActor @Suite struct ChecklistCommandReturnKeysTests {
    static let registry: ActionRegistry = {
        let registry = ActionRegistry.standard()
        registry.bind("toggleChecklistItemComplete", invoke: { _ in })
        return registry
    }()

    static func decision(_ resolved: FocusState.Resolved) throws -> String {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
                                                  windowNumber: 0, context: nil, characters: "\r",
                                                  charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        var focus = FocusState()
        focus.resolved = resolved
        return String(describing: KeyRouter(registry: registry).decide(event, focus: focus, keyWindow: .content, facts: KeyFacts()))
    }

    @Test func theAgentComposerGetsCommandReturn() throws {
        #expect(try Self.decision(.agentPage(pane: "pane_agent", tab: "tab_agent")) == "deliver")
    }

    @Test func aWebPageGetsCommandReturn() throws {
        #expect(try Self.decision(.browserPage(pane: "pane_web", tab: "tab_web")) == "deliver")
    }

    /// The Todo page (an internal page) keeps the toggle.
    @Test func theTodoPageStillToggles() throws {
        #expect(try Self.decision(.page(pane: "pane_todo", tab: "tab_todo")).contains("toggleChecklistItemComplete"))
    }
}
