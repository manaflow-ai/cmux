import AppKit
import CmuxNextActions
@testable import CmuxNextPalette
import CmuxNextTestSupport
import Testing

/// The palette audit's order (plans/cmux-next/palette-ranking.md 5.4): a family folds into one row
/// on the empty query and its members still match a query; daily rows lead, niche rows trail and
/// rows the focused pane cannot run come last;
/// a built-in alias puts its command first; nothing is dropped.
@MainActor
@Suite(.closesItsWindows)
struct PaletteFamilyRowsTests {
    @Test func familiesFoldOnTheEmptyQueryAndNoActionIsDropped() async throws {
        let registry = ActionRegistry.standard()
        let items = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        let actionRows = Set(items.compactMap(\.actionID))
        let expected = Set(registry.entries.map(\.descriptor)
            .filter { $0.isPaletteVisible && $0.id != "commandPalette" && registry.isAvailable($0.id) }.map(\.id))
        #expect(actionRows == expected)

        let move = try #require(items.first { $0.id == "family:workspace.move" })
        #expect(move.title == "Workspace: Move…")
        #expect(move.keywords.contains("Move Workspace Up"))
        guard case .push(let page) = move.primary.effect.resolved() else {
            Issue.record("Workspace: Move… does not open a page")
            return
        }
        let listed = page.providers.flatMap { ($0 as? StaticPaletteProvider)?.itemsList ?? [] }
        #expect(listed.contains { $0.actionID == "moveWorkspaceUp" && !$0.hidesWhenQueryEmpty })
        #expect(try #require(items.first { $0.actionID == "moveWorkspaceUp" }).hidesWhenQueryEmpty)

        // A parent stands for its family and matches the members' titles.
        let setColor = try #require(items.first { $0.actionID == "space.setColor" })
        #expect(setColor.keywords.contains("Space Color: Red"))
        #expect(try #require(items.first { $0.actionID == "space.color.red" }).hidesWhenQueryEmpty)
    }

    @Test func dailyRowsLeadAndNicheRowsTrail() {
        func item(_ id: String) -> PaletteItem {
            PaletteItem(id: id, title: id, primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
        }
        var disabled = item("e")
        disabled.isEnabled = false
        let arranged = RegistryPaletteProvider.arranged(
            [disabled, item("a"), item("b"), item("c"), item("d")],
            tiers: ["a": .niche, "b": .standard, "c": .daily, "d": .niche, "e": .daily]
        )
        // A row the focused pane cannot run stays listed, last.
        #expect(arranged.map(\.id) == ["c", "b", "a", "d", "e"])
        #expect(!arranged[4].hidesWhenQueryEmpty)
        #expect(RegistryPaletteProvider.rankBias(for: .daily) > 0)
        #expect(RegistryPaletteProvider.rankBias(for: .niche) < 0)
    }

    @Test func aBuiltInAliasPutsItsCommandFirstAndAMemberStillMatches() async {
        _ = NSApplication.shared
        let registry = ActionRegistry.standard()
        registry.bind("appearance.customize") {}
        registry.bind("moveWorkspaceUp") {}
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        defer { palette.closeForTest() }
        palette.show(.commands)
        await palette.model.settle()

        palette.model.send(.setQuery("font"))
        await palette.model.settle()
        #expect(palette.model.rows.first?.item.actionID == "appearance.customize")

        palette.model.send(.setQuery("Move Workspace Up"))
        await palette.model.settle()
        #expect(palette.model.rows.contains { $0.item.actionID == "moveWorkspaceUp" })
    }
}
