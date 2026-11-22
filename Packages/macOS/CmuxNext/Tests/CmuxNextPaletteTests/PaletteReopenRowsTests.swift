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
        let first = Flag()
        try #require(registry.bind("newWindow") {})
        ActionTargetTitles.setPaletteTitle("newWindow", in: registry) { first.on ? "New Window" : "New Window Again" }
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let (_, before) = try Self.open(palette)
        #expect(before.first { $0.actionID == "newWindow" }?.title == "New Window")
        first.on = false
        let (second, after) = try Self.open(palette)
        #expect(second.builtRows == 1, "one row changed; the reopen built \(second.builtRows)")
        let row = try #require(after.first { $0.actionID == "newWindow" }, "the changed row left the list")
        #expect(row.title == "New Window Again", "the changed row shows its old state")
        let sameRows = Set(after.map { $0.id }) == Set(before.map { $0.id })
        #expect(sameRows, "the reopen lists other rows")
    }

    /// A row that stops running leaves the next open's list (Leo 2026-11-17: "just... stop showijg the toggle on
    /// gui") and is listed again, from the kept row, once it runs.
    @Test func aRowThatStopsRunningLeavesTheReopenAndComesBack() throws {
        let registry = ActionRegistry.standard()
        let canOpen = Flag()
        try #require(registry.bind("newWindow", isEnabled: { canOpen.on }) {})
        let palette = Self.palette(registry)
        defer { palette.closeForTest() }
        let (_, before) = try Self.open(palette)
        #expect(before.first { $0.actionID == "newWindow" }?.isEnabled == true)
        canOpen.on = false
        let (second, after) = try Self.open(palette)
        #expect(second.builtRows == 0, "no listed row changed; the reopen built \(second.builtRows)")
        #expect(!after.contains { $0.actionID == "newWindow" }, "a row that cannot run is listed")
        canOpen.on = true
        let (third, again) = try Self.open(palette)
        #expect(third.builtRows == 0, "the row came back built again")
        #expect(again.first { $0.actionID == "newWindow" }?.isEnabled == true, "the row that runs again is not listed")
    }

    /// The overrides each open served, in the order they ran.
    private final class Served { var names: [String] = [] }

    /// A row kept from an earlier open runs what the palette serves at this open: its override is decided when it
    /// runs, from the newest open, never from the open that built it.
    @Test func aKeptRowRunsTheNewestOpensOverride() throws {
        let registry = ActionRegistry.standard()
        try #require(registry.bind("newWindow") {})
        let rows = RegistryPaletteRows()
        let served = Served()
        func open(_ name: String) throws -> (RegistryPaletteProvider, PaletteItem) {
            let provider = RegistryPaletteProvider(registry: registry)
            provider.rows = rows
            provider.effectOverrides["newWindow"] = {
                served.names.append(name)
                return .perform {}
            }
            return (provider, try #require(provider.makeItems().first { $0.actionID == "newWindow" }))
        }
        _ = try open("first")
        let (second, row) = try open("second")
        #expect(second.builtRows == 0, "the reopen built \(second.builtRows) rows")
        _ = row.primary.effect.resolved()
        #expect(served.names == ["second"], "the kept row ran \(served.names)")
    }
}
