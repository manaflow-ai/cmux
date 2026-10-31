import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// ``PaletteController/commandEntries()`` lists the Commands palette's runnable rows, and
/// ``PaletteController/runCommand(_:relativeTo:)`` runs one as the palette would: the shared
/// source another surface (the New Tab page's dropdown) lists actions from.
@MainActor
struct PaletteCommandEntriesTests {
    private static func registry() -> ActionRegistry {
        let registry = ActionRegistry.standard()
        registry.context = ActionContext(rawValue: .max)
        return registry
    }

    @Test func theEntriesAreThePalettesRunnableRows() {
        let registry = Self.registry()
        for descriptor in registry.descriptors where descriptor.isPaletteVisible && descriptor.arguments.isEmpty {
            registry.bind(descriptor.id) {}
        }
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        palette.hiddenActionIDs = { ["newWindow"] }
        let rows = palette.makeRegistryProvider().makeItems().filter(\.isEnabled).compactMap(\.actionID)
        let clock = ContinuousClock()
        var entries: [PaletteCommandEntry] = []
        let elapsed = clock.measure { entries = palette.commandEntries() }
        // Every New Tab page opening pays this once (NewTabPage.omnibar).
        print("palette-command-entries: \(entries.count) entries in \(elapsed)")
        #expect(entries.map(\.id) == rows)
        #expect(entries.count > 40)
        #expect(!entries.contains { $0.id == "newWindow" || $0.id == "commandPalette" })
        #expect(entries.allSatisfy { !$0.title.isEmpty && !$0.section.isEmpty })
    }

    /// The rows are kept per focus context and per hidden set (``PaletteCommandEntryCache``): focus that leaves
    /// and comes back builds nothing, another context gets its own rows, and a binding change drops them all.
    @Test func theEntriesAreKeptPerContextAndDroppedWhenABindingChanges() {
        let registry = Self.registry()
        for descriptor in registry.descriptors where descriptor.isPaletteVisible && descriptor.arguments.isEmpty {
            registry.bind(descriptor.id) {}
        }
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        let cache = palette.commandEntryCache
        let everything = palette.commandEntries()
        #expect(palette.commandEntries() == everything)
        #expect(cache.builds == 1)
        // Another focus context: its own rows (fewer actions are available with no facts).
        let full = registry.context
        registry.context = []
        let bare = palette.commandEntries()
        #expect(cache.builds == 2)
        #expect(bare.count < everything.count)
        // Back to the first context: the kept rows, no build.
        registry.context = full
        #expect(palette.commandEntries() == everything)
        #expect(cache.builds == 2)
        // Another hidden set is another key.
        palette.hiddenActionIDs = { ["newWindow"] }
        #expect(!palette.commandEntries().contains { $0.id == "newWindow" })
        #expect(cache.builds == 3)
        // A binding change drops every kept list.
        registry.bind("newWindow") {}
        _ = palette.commandEntries()
        #expect(cache.builds == 4)
    }

    /// The opt-in check (`verifiesHits`): a kept list that a fresh build disagrees with is
    /// counted and the fresh rows are returned, so a source the cache misses shows up in a dogfood run.
    @Test func theCheckReturnsFreshRowsWhenAKeptListIsStale() {
        let registry = Self.registry()
        var open = true // a plain variable: not observable, so the cache cannot see it change
        registry.bind("newWindow", isEnabled: { open }) {}
        let palette = PaletteController(registry: registry, frecencyPersistence: nil,
                                        commandEntryCache: PaletteCommandEntryCache(verifiesHits: true))
        #expect(palette.commandEntries().contains { $0.id == "newWindow" })
        open = false
        #expect(!palette.commandEntries().contains { $0.id == "newWindow" })
        #expect(palette.commandEntryCache.staleHits == 1)
    }

    @Test func aPlainCommandRunsWithoutShowingThePalette() {
        let registry = Self.registry()
        var ran = 0
        registry.bind("newWindow") { ran += 1 }
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        #expect(palette.runCommand("newWindow"))
        #expect(ran == 1)
        #expect(!palette.isVisible)
        // An action the palette does not offer here is refused, not run.
        #expect(!palette.runCommand("commandPalette"))
    }
}
