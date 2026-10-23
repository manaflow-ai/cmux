@testable import CmuxNextActions
@testable import CmuxNextPalette
import Testing

/// Actions removed from the tab pointer menu remain first-class palette commands. This is the
/// contract that lets a compact menu move its long tail without making a command unreachable.
@MainActor @Suite(.paletteRanker)
struct TabMenuTrimPaletteTests {
    @Test func everyTrimmedTabActionResolvesFromItsPaletteTitle() throws {
        let registry = ActionRegistry.standard()
        let items = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        var index = PaletteSearchIndex(items: items)
        let ranker = PaletteRanker()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let frecency = FrecencyStore()

        for id in ContextMenuEssentials.tabMenuTrimmedActions {
            let expected = try #require(items.first { $0.actionID == id }, "palette item for \(id)")
            let expectedIndex = try #require(index.entries.firstIndex { $0.actionID == id.rawValue })
            let sections = ranker.rank(index: &index, version: 1, query: expected.title,
                                       sectionOrders: [], frecency: frecency, now: now, showsRecent: false)
            #expect(sections.flatMap(\.rows).contains { $0.index == expectedIndex },
                    "palette search for \(expected.title) resolves \(id)")
        }
    }
}
