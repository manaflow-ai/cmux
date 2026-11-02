import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Shift-Cmd-P builds no command row that has not changed since the last open (SHORTCUT PERF 2). On the bench (light,
/// 120 Hz) every open spent 14 ms in `RegistryPaletteProvider.makeItems` building a row per catalog action, sorting
/// them and folding the families, in the key's turn. The palette keeps its rows across opens and rebuilds, by action
/// id, only the rows whose shown state changed.
@MainActor
@Suite(.paletteRanker, .serialized, .closesItsWindows)
struct PaletteReopenRowsTests {
    private static func palette(_ registry: ActionRegistry) -> PaletteController {
        _ = NSApplication.shared
        return PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
    }

    /// The command page's registry rows, as an open reads them, and the provider that built them.
    private static func open(_ palette: PaletteController) throws -> (RegistryPaletteProvider, [PaletteItem]) {
        let provider = try #require(palette.commandsPage().providers.lazy.compactMap { $0 as? RegistryPaletteProvider }.first)
        return (provider, try #require(provider.immediateItems))
    }

    /// The facts a person sees on a row, in list order.
    private static func shown(_ items: [PaletteItem]) -> [String] {
        items.map { "\($0.id)|\($0.title)|\($0.subtitle ?? "")|\($0.isEnabled)|\($0.keycaps ?? [])|\($0.hidesWhenQueryEmpty)" }
    }

    @Test func aReopenWithNothingChangedBuildsNoRow() throws {
        let palette = Self.palette(.standard())
        defer { palette.closeForTest() }
        let (first, firstItems) = try Self.open(palette)
        #expect(first.builtRows > 0, "the first open built no row")
        let (second, secondItems) = try Self.open(palette)
        #expect(second.builtRows == 0, "a reopen with nothing changed built \(second.builtRows) rows again")
        #expect(Self.shown(secondItems) == Self.shown(firstItems), "the reopen lists other rows")
    }

    /// A state an action's `isEnabled` reads.
    private final class Flag { var on = true }

    @Test func aReopenRebuildsOnlyTheRowThatChanged() throws {
        let registry = ActionRegistry.standard()
        let canOpen = Flag()
        try #require(registry.bind("newWindow", isEnabled: { canOpen.on }) {})
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let (_, before) = try Self.open(palette)
        #expect(before.first { $0.actionID == "newWindow" }?.isEnabled == true)
        canOpen.on = false
        let (second, after) = try Self.open(palette)
        #expect(second.builtRows == 1, "one row changed; the reopen built \(second.builtRows)")
        let row = try #require(after.first { $0.actionID == "newWindow" }, "the changed row left the list")
        #expect(!row.isEnabled, "the changed row shows its old state")
        // A row that cannot run lists after every row that can (`RegistryPaletteProvider.arranged`).
        let index = try #require(after.firstIndex { $0.actionID == "newWindow" })
        let enabledAfter = after[index...].contains { $0.isEnabled }
        #expect(!enabledAfter, "the disabled row lists before an enabled one")
        let sameRows = Set(after.map { $0.id }) == Set(before.map { $0.id })
        #expect(sameRows, "the reopen lists other rows")
    }
}
