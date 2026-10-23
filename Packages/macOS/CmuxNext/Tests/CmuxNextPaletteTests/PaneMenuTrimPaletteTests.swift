import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Removing a row from the pane pointer menu must never remove its canonical
/// command. Every trimmed action remains discoverable by its palette title.
@MainActor
@Suite(.paletteRanker)
struct PaneMenuTrimPaletteTests {
    private static let paletteOnly: Set<ActionID> = [
        "newPaneAutoLayout", "triggerFlash", "palette.swapWithSession", "toggleCanvasLayout", "palette.newSimulatorPane",
        "remote.openTerminalHere", "column.moveLeft", "column.moveRight", "column.center", "column.widthOneThird",
        "column.widthHalf", "column.widthTwoThirds", "column.widthFull", "column.dock", "column.undock", "column.float",
        "column.dockLeft", "column.dockRight", "column.dockTop", "column.dockBottom",
    ]

    @Test func everyTrimmedPaneActionResolvesFromPaletteSearch() async throws {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.hide() }
        palette.show(.commands)
        await palette.model.settle()

        for id in Self.paletteOnly {
            let descriptor = try #require(registry.descriptor(for: id))
            palette.model.send(.setQuery(descriptor.title))
            await palette.model.settle()
            #expect(palette.model.rows.contains { $0.item.actionID == id }, "palette search lost \(id) / \(descriptor.title)")
        }
    }
}
