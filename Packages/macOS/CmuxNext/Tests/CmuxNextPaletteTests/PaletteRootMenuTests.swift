import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

@MainActor
struct PaletteRootMenuTests {
    private func catalogProvider() throws -> RegistryPaletteProvider {
        let registry = ActionRegistry.standard()
        // Exercise the complete catalog rather than one pane's available subset.
        for descriptor in registry.descriptors {
            registry.context.formUnion(descriptor.requires)
            registry.bind(descriptor.id) {}
        }
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        return try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
    }

    @Test func emptyRootHasABoundedSetOfUsefulIntents() throws {
        let items = try catalogProvider().makeItems()
        let visible = items.filter { !$0.hidesWhenQueryEmpty }
        #expect(visible.count <= 138)
        let actions = Set(visible.compactMap(\.actionID))
        for id: ActionID in ["newTab", "newTab.default", "newSurface", "closeTab", "renameTab", "splitRight", "openSettings"] {
            #expect(actions.contains(id), "\(id) remains a direct root intent")
        }
        #expect(visible.filter { $0.id.hasPrefix("rootFamily:") }.count == 8)
    }

    @Test func everyActionRemovedFromTheRootStillResolvesByNameAndID() throws {
        let provider = try catalogProvider()
        let items = provider.makeItems()
        let removed = items.filter { $0.actionID != nil && $0.hidesWhenQueryEmpty }
        #expect(removed.count > 400)
        let ranker = PaletteRanker()
        if let error = ranker.loadError {
            Issue.record("Palette ranker failed to load: \(error)")
            return
        }
        var index = PaletteSearchIndex(items: items)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for item in removed {
            let id = try #require(item.actionID)
            for query in [id.rawValue, item.title] {
                let found = ranker.rank(index: &index, version: 1, query: query, sectionOrders: [],
                                        frecency: FrecencyStore(), now: now, showsRecent: false)
                    .flatMap(\.rows).contains { items[$0.index].actionID == id }
                #expect(found, "Removed root action \(id) resolves from palette search '\(query)'")
            }
        }
    }
}
