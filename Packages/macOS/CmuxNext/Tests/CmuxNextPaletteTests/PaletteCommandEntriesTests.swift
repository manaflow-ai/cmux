import CmuxNextActions
import Observation
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
    /// Builds are counted through New Window's palette title, which every build reads once (it needs no focus facts).
    @Test func theEntriesAreKeptPerContextAndDroppedWhenABindingChanges() {
        let registry = Self.registry()
        for descriptor in registry.descriptors where descriptor.isPaletteVisible && descriptor.arguments.isEmpty {
            registry.bind(descriptor.id) {}
        }
        var builds = 0
        ActionTargetTitles.setPaletteTitle("newWindow", in: registry) {
            builds += 1
            return nil
        }
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        let everything = palette.commandEntries()
        #expect(palette.commandEntries() == everything)
        #expect(builds == 1)
        // Another focus context: its own rows (fewer actions are available with no facts).
        let full = registry.context
        registry.context = []
        let bare = palette.commandEntries()
        #expect(builds == 2)
        #expect(bare.count < everything.count)
        // Back to the first context: the kept rows, no build (a focus move does not drop them).
        registry.context = full
        #expect(palette.commandEntries() == everything)
        #expect(builds == 2)
        // Another hidden set is another key.
        palette.hiddenActionIDs = { ["splitRight"] }
        _ = palette.commandEntries()
        #expect(builds == 3)
        // A binding change drops every kept list.
        #expect(registry.bind("splitRight") {})
        _ = palette.commandEntries()
        #expect(builds == 4)
    }

    /// A row's availability that reads observable state: its first change drops the kept rows, so a surface
    /// never lists a row that cannot run.
    @Test func aRowThatTurnsUnavailableLeavesTheNextEntries() {
        let registry = Self.registry()
        let gate = PaletteEntryGate()
        registry.bind("newWindow", isEnabled: { gate.open }) {}
        let palette = PaletteController(registry: registry, frecencyPersistence: nil)
        #expect(palette.commandEntries().contains { $0.id == "newWindow" })
        gate.open = false
        #expect(!palette.commandEntries().contains { $0.id == "newWindow" })
        gate.open = true
        #expect(palette.commandEntries().contains { $0.id == "newWindow" })
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

/// Observable state a row's availability reads (``PaletteCommandEntriesTests/aRowThatTurnsUnavailableLeavesTheNextEntries()``).
@MainActor @Observable
final class PaletteEntryGate {
    var open = true
}
