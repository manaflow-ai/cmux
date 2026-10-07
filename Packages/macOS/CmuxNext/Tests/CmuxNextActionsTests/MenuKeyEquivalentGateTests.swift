import AppKit
@testable import CmuxNextActions
import Testing

/// A main-menu key equivalent asks the registry's gate (the App's key
/// router) before it runs, so a chord the router gave to a page or a text
/// field cannot fire the menu item afterwards (plans/cmux-next/focus.md 5).
@MainActor
struct MenuKeyEquivalentGateTests {
    @Test func keyEquivalentIsRefusedWhenTheGateSaysNo() {
        let registry = ActionRegistry.standard()
        registry.bind("splitRight", invoke: { _ in })
        registry.isDispatchingKeyDown = { true }
        registry.menuKeyEquivalentGate = { _ in false }
        let item = registry.makeMenuItem(for: "splitRight")!
        #expect(!item.keyEquivalent.isEmpty)
        #expect(!registry.menuTarget.validateMenuItem(item))
        registry.menuKeyEquivalentGate = { _ in true }
        #expect(registry.menuTarget.validateMenuItem(item))
    }

    @Test func clicksInAnOpenMenuAreNotGated() {
        let registry = ActionRegistry.standard()
        registry.bind("splitRight", invoke: { _ in })
        registry.isDispatchingKeyDown = { false }
        registry.menuKeyEquivalentGate = { _ in false }
        #expect(registry.menuTarget.validateMenuItem(registry.makeMenuItem(for: "splitRight")!))
    }
}
