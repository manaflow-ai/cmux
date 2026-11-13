import AppKit
import CmuxNextActions
import Testing

/// Shift-Cmd-I no longer opens the Feed panel: the panel and its `feed.show` action are gone
/// (user, 2026-11-07: "get rid of cmd shift i feed thing"). The key is left unbound, and the
/// palette and Window menu have no Show Feed row.
@MainActor @Suite struct FeedShortcutRemovedTests {
    private func resolve(in context: ActionContext) throws -> String? {
        // The app binds a handler to every catalog action; a key runs only a bound one.
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        registry.context = context
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift, .command], timestamp: 0, windowNumber: 0, context: nil,
            characters: "I", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34
        ))
        return registry.resolveShortcut(for: event)?.id.rawValue
    }

    @Test func shiftCommandIRunsNoAction() throws {
        #expect(try resolve(in: []) == nil)
    }

    @Test func theCatalogHasNoShowFeedAction() {
        let ids = Set(ActionCatalog.all.map(\.id.rawValue))
        #expect(!ids.contains("feed.show"))
        #expect(ActionCatalog.legacyAliases["agentInbox"] == nil)
        #expect(!ActionCatalog.all.contains { $0.defaultShortcut == Shortcut("i", modifiers: [.command, .shift]) })
    }
}
