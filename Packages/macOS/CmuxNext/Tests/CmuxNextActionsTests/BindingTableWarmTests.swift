import AppKit
@testable import CmuxNextActions
import Testing

/// TYPING UNDER LOAD finding F3 (2026-11-02, real-app video on cmux20): the key-binding table was built lazily by the
/// first key that needed it (`KeyRouter.resolve` -> `RegistryKeyBindings.table` -> `makeTable()`), 27.6 ms on the
/// main thread on a typed Left arrow. The registry must build a stale table on the warm hook the app gives it (a
/// budgeted background batch on the main thread, which yields to a person's input), before a key needs it, and
/// coalesce many changes into one build.
@MainActor @Suite struct BindingTableWarmTests {
    private static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        for descriptor in ActionCatalog.all { registry.bind(descriptor.id) {} }
        return registry
    }

    @Test func aStaleTableIsBuiltOnTheWarmHookBeforeAnyKey() throws {
        let registry = Self.registry()
        _ = RegistryKeyBindings(registry).table  // a built table, as after the first key
        #expect(registry.shortcutIndex?.bindingTable != nil)
        var queued: [@MainActor () -> Void] = []
        registry.warmBindingTable = { queued.append($0) }
        #expect(queued.isEmpty, "a built table asks for nothing")
        registry.seed(Array(ActionCatalog.all.prefix(1)))  // any change makes the table stale
        #expect(registry.shortcutIndex?.bindingTable == nil)
        try #require(queued.count == 1, "a stale table asks the warm hook once")
        queued.forEach { $0() }
        #expect(registry.shortcutIndex?.bindingTable != nil, "the warm hook built the table: no key pays for it")
    }

    @Test func manyChangesInOneTurnAskForOneBuild() {
        let registry = Self.registry()
        _ = RegistryKeyBindings(registry).table
        var queued: [@MainActor () -> Void] = []
        registry.warmBindingTable = { queued.append($0) }
        for descriptor in ActionCatalog.all.prefix(5) { registry.seed([descriptor]) }
        registry.disabledFeatures = []
        #expect(queued.count == 1, "changes before the warm ran coalesce: \(queued.count) builds asked")
        queued.forEach { $0() }
        registry.seed(Array(ActionCatalog.all.prefix(1)))
        #expect(queued.count == 2, "a change after the warm ran asks again")
    }

    @Test func aNewHookAsksAgainWhenTheOldOnesWorkWasDropped() {
        let registry = Self.registry()
        var dropped: [@MainActor () -> Void] = []
        registry.warmBindingTable = { dropped.append($0) }  // stale from the start: asked once
        var queued: [@MainActor () -> Void] = []
        registry.warmBindingTable = { queued.append($0) }
        #expect(queued.count == 1, "the new hook is asked, so the table does not wait for a key")
        queued.forEach { $0() }
        #expect(registry.shortcutIndex?.bindingTable != nil)
    }
}
