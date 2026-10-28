import CmuxNextActions
@testable import CmuxNextPalette
import Foundation
import Testing

@MainActor
struct PaletteRootMenuTests {
    private func catalogPalette() -> PaletteController {
        let registry = ActionRegistry.standard()
        for descriptor in registry.descriptors {
            registry.context.formUnion(descriptor.requires)
            registry.bindEffect(descriptor.id) { _ in .done }
        }
        return PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
    }

    private func items(in page: PalettePageSpec) throws -> [PaletteItem] {
        try #require(page.providers.first as? RegistryPaletteProvider).makeItems()
    }

    private func members(of row: PaletteItem) throws -> [PaletteItem] {
        guard case .push(let page) = row.primary.effect.resolved() else {
            Issue.record("\(row.id) does not open a family page")
            return []
        }
        return page.providers.flatMap { ($0 as? StaticPaletteProvider)?.itemsList ?? [] }
    }

    @Test func emptyRootKeepsCommonIntentsAndEightFamilies() throws {
        let palette = catalogPalette()
        let visible = try items(in: palette.commandsPage()).filter { !$0.hidesWhenQueryEmpty }
        let direct = Set(visible.compactMap(\.actionID))
        #expect(direct.count == 130)
        for id: ActionID in ["newTab", "newTab.default", "newSurface", "closeTab", "renameTab", "splitRight", "openSettings"] {
            #expect(direct.contains(id), "\(id) remains a direct root intent")
        }
        let families = Set(visible.filter { $0.actionID == nil }.map(\.id))
        #expect(families == Set([
            "rootFamily:window", "rootFamily:workspace", "rootFamily:tab", "rootFamily:browser",
            "rootFamily:terminal", "rootFamily:agents", "rootFamily:cloud", "rootFamily:settings",
        ]))
    }

    @Test func broadFamiliesPreserveTheExistingDetailedGroups() throws {
        let palette = catalogPalette()
        let root = try items(in: palette.commandsPage())
        let full = try items(in: palette.commandsOnlyPage())
        let groups: [(String, Set<ActionCategory>)] = [
            ("window", [.window, .pane, .screen, .other]), ("workspace", [.workspace, .sidebar]),
            ("tab", [.tab]), ("browser", [.browser]), ("terminal", [.terminal]), ("agents", [.agents]),
            ("cloud", [.cloud, .remote]), ("settings", [.settings, .notifications]),
        ]
        for (name, categories) in groups {
            let row = try #require(root.first { $0.id == "rootFamily:\(name)" })
            let listed = try members(of: row)
            let sectionIDs = Set(categories.map(\.paletteSectionID))
            let expected = full.filter { sectionIDs.contains($0.section.id) }
            #expect(listed.map(\.id) == expected.map(\.id))
            #expect(listed.map(\.hidesWhenQueryEmpty) == expected.map(\.hidesWhenQueryEmpty))
        }
        let workspace = try #require(root.first { $0.id == "rootFamily:workspace" })
        let listed = try members(of: workspace)
        let move = try #require(listed.first { $0.id == "family:workspace.move" })
        #expect(!move.hidesWhenQueryEmpty)
        #expect(try #require(listed.first { $0.actionID == "moveWorkspaceUp" }).hidesWhenQueryEmpty)
        #expect(try members(of: move).contains { $0.actionID == "moveWorkspaceUp" && !$0.hidesWhenQueryEmpty })
    }

    @Test func commandsScopeKeepsTheCompleteCatalog() throws {
        let palette = catalogPalette()
        let root = try items(in: palette.commandsPage())
        let scope = try items(in: palette.commandsOnlyPage())
        let ordinary = RegistryPaletteProvider(registry: palette.registry, includeUnbound: true).makeItems()
        #expect(Set(root.compactMap(\.actionID)) == Set(scope.compactMap(\.actionID)))
        #expect(scope.map(\.id) == ordinary.map(\.id))
        #expect(scope.map(\.hidesWhenQueryEmpty) == ordinary.map(\.hidesWhenQueryEmpty))
        #expect(try #require(scope.first { $0.actionID == "history.commands" }).hidesWhenQueryEmpty == false)
        #expect(try #require(root.first { $0.actionID == "history.commands" }).hidesWhenQueryEmpty)
        print("Palette root: \(scope.filter { !$0.hidesWhenQueryEmpty }.count) -> \(root.filter { !$0.hidesWhenQueryEmpty }.count); searchable actions: \(root.compactMap(\.actionID).count)")
    }

    @Test func rootExcludesUnboundDebugAndNewLongTailActionsButIncludesOverrides() throws {
        var debug = try #require(ActionRegistry.standard().descriptor(for: "newTab"))
        debug.isDebugOnly = true
        let tab = try #require(ActionRegistry.standard().descriptor(for: "newSurface"))
        let close = try #require(ActionRegistry.standard().descriptor(for: "closeWindow"))
        let future = ActionDescriptor(id: "future.setting", title: "Future Setting", category: .settings)
        let registry = ActionRegistry(catalog: [debug, tab, close, future], runTiming: NoActionRunTiming())
        registry.bindEffect(debug.id) { _ in .done }
        registry.bindEffect(future.id) { _ in .done }
        let palette = PaletteController(registry: registry, sources: PaletteSources(), frecencyPersistence: nil)
        let provider = try #require(palette.commandsPage().providers.first as? RegistryPaletteProvider)
        provider.includeUnbound = true
        provider.effectOverrides[tab.id] = { .perform {} }
        let visible = provider.makeItems().filter { !$0.hidesWhenQueryEmpty }
        #expect(Set(visible.compactMap(\.actionID)) == Set([tab.id]))
        #expect(Set(visible.filter { $0.actionID == nil }.map(\.id)) == Set(["rootFamily:tab", "rootFamily:settings"]))
    }

    @Test(.paletteRanker) func everyHiddenActionStillResolvesByNameAndID() throws {
        let palette = catalogPalette()
        let root = try items(in: palette.commandsPage())
        let hidden = root.filter { $0.actionID != nil && $0.hidesWhenQueryEmpty }
        #expect(hidden.count > 130)
        let families = root.filter { $0.id.hasPrefix("rootFamily:") }
        let familiesHideWhenTyping = families.allSatisfy { $0.hidesWhenTyping }
        #expect(familiesHideWhenTyping)
        let ranker = PaletteRanker()
        var index = PaletteSearchIndex(items: root)
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        for item in hidden {
            let id = try #require(item.actionID)
            for query in [id.rawValue, item.title] {
                let results = ranker.rank(index: &index, version: 1, query: query, sectionOrders: [],
                                          frecency: FrecencyStore(), now: now, showsRecent: false)
                    .flatMap(\.rows).map { root[$0.index] }
                #expect(results.contains { $0.actionID == id }, "Hidden root action \(id) resolves from '\(query)'")
                #expect(!results.contains { $0.id.hasPrefix("rootFamily:") })
            }
        }
    }
}
