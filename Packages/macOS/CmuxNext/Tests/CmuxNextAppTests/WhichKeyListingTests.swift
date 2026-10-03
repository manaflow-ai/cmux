import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import Testing

/// The which-key overlay's rows (`WhichKeyListing`): one per binding under
/// the leader, by key, with the action's title, dimmed when it cannot run.
@MainActor
struct WhichKeyListingTests {
    @Test func rowsListTheBindingsUnderThePrefixByKey() {
        let registry = ActionRegistry(catalog: [
            ActionDescriptor(id: "alpha", title: "Alpha", category: .terminal),
            ActionDescriptor(id: "bravo", title: "Bravo", category: .terminal),
            ActionDescriptor(id: "other", title: "Other Prefix", category: .terminal),
        ])
        registry.bind("alpha") {}
        registry.setChordOverride(ShortcutChord(LeaderLayer.prefix, Shortcut("x", modifiers: [])), for: "alpha")
        registry.setChordOverride(ShortcutChord(LeaderLayer.prefix, Shortcut("b", modifiers: [])), for: "bravo")
        registry.setChordOverride(ShortcutChord(Shortcut("b", modifiers: [.control]), Shortcut("c", modifiers: [])), for: "other")
        #expect(WhichKeyListing.rows(after: LeaderLayer.prefix, in: registry) == [
            WhichKeyRow(key: "B", title: "Bravo", isEnabled: false),
            WhichKeyRow(key: "X", title: "Alpha", isEnabled: true),
        ])
    }

    @Test func theStandardLeaderListsItsDefaults() {
        let registry = ActionRegistry.standard()
        registry.bind("terminal.scrollToSelection") {}
        let rows = WhichKeyListing.rows(after: LeaderLayer.prefix, in: registry)
        #expect(rows.map(\.key) == ["J", "S", "⇧/"])
        #expect(rows.first?.title == registry.title(for: "terminal.scrollToSelection"))
        #expect(rows.first?.isEnabled == true)
    }

    @Test func aPrefixWithoutBindingsHasNoRows() {
        let registry = ActionRegistry.standard()
        #expect(WhichKeyListing.rows(after: Shortcut("b", modifiers: [.control]), in: registry).isEmpty)
    }
}
