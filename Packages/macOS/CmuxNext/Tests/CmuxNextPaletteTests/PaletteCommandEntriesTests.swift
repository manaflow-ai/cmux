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
