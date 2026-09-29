import CmuxNextActions
import CmuxNextPalette
import Foundation
import Testing

@Suite struct PaletteRankingTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func catalogIndex() -> PaletteSearchIndex {
        let provider = RegistryPaletteProvider(registry: .standard(), includeUnbound: true)
        return PaletteSearchIndex(items: provider.makeItems())
    }

    func topID(_ query: String, index: PaletteSearchIndex, frecency: FrecencyStore = FrecencyStore()) -> String? {
        PaletteRanker.rank(index: index, query: query, frecency: frecency, now: now, showsRecent: false)
            .flatMap(\.rows)
            .sorted { $0.score > $1.score }
            .first?.id
    }

    @Test func catalogQueriesRankTheObviousActionFirst() {
        let index = catalogIndex()
        #expect(topID("split r", index: index) == "action:splitRight")
        #expect(topID("close tab", index: index) == "action:closeTab")
        #expect(topID("new window", index: index) == "action:newWindow")
        #expect(topID("tfs", index: index) == "action:toggleFullScreen")
        #expect(topID("rename tab", index: index) == "action:renameTab")
        #expect(topID("newSurface", index: index) == "action:newSurface")
    }

    @Test func keywordsAndAliasesMatch() {
        let index = catalogIndex()
        // "preferences" is only a keyword of Settings….
        #expect(topID("preferences", index: index) == "action:openSettings")
    }

    @Test func contextHidesActionsThatDoNotApply() {
        let registry = ActionRegistry.standard()
        let provider = RegistryPaletteProvider(registry: registry, includeUnbound: true)
        #expect(!provider.makeItems().contains { $0.id == "action:browserReload" })
        registry.context = [.browserFocused]
        #expect(provider.makeItems().contains { $0.id == "action:browserReload" })
    }

    @Test func unboundActionsAreDisabledOrHidden() {
        let registry = ActionRegistry.standard()
        registry.bind("splitRight") {}
        let debugItems = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        #expect(debugItems.first { $0.id == "action:splitRight" }?.isEnabled == true)
        #expect(debugItems.first { $0.id == "action:splitDown" }?.isEnabled == false)
        let releaseItems = RegistryPaletteProvider(registry: registry, includeUnbound: false).makeItems()
        #expect(releaseItems.map(\.id) == ["action:splitRight"])
    }

    @Test func shortcutSearchFindsByKeys() {
        let registry = ActionRegistry.standard()
        let index = PaletteSearchIndex(items: KeyboardShortcutsPaletteProvider(registry: registry).makeItems())
        #expect(topID("⇧⌘P", index: index) == "shortcut:commandPalette")
        #expect(topID("cmd d split", index: index) == "shortcut:splitRight")
        // Every catalog action with a default shortcut or label is listed.
        let expected = ActionCatalog.all.filter { $0.defaultShortcut != nil || $0.shortcutLabel != nil }.count
        #expect(index.items.count == expected)
    }

    @Test func frecencyBreaksTiesButDoesNotBeatClearlyBetterMatches() {
        func item(_ id: String, _ title: String) -> PaletteItem {
            PaletteItem(id: id, title: title, primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
        }
        let index = PaletteSearchIndex(items: [
            item("right", "Split Right"),
            item("down", "Split Down"),
            item("folder", "Open Folder"),
            item("weak", "Buffer Scroll Load"),
        ])
        var frecency = FrecencyStore()
        #expect(topID("split", index: index, frecency: frecency) == "right")
        for _ in 0..<5 { frecency.record("down", at: now) }
        #expect(topID("split", index: index, frecency: frecency) == "down")

        for _ in 0..<1000 { frecency.record("weak", at: now) }
        #expect(frecency.boost(for: "weak", at: now) == FrecencyStore.maximumBoost)
        #expect(topID("fold", index: index, frecency: frecency) == "folder")
    }

    @Test func frecencyDecaysWithHalfLife() {
        var store = FrecencyStore(halfLife: 100)
        store.record("a", at: now)
        store.record("a", at: now)
        #expect(abs(store.score(for: "a", at: now) - 2) < 0.0001)
        #expect(abs(store.score(for: "a", at: now.addingTimeInterval(100)) - 1) < 0.0001)
        #expect(abs(store.score(for: "a", at: now.addingTimeInterval(200)) - 0.5) < 0.0001)
        store.record("b", at: now.addingTimeInterval(200))
        // Fresh single use (1.0) beats an old double use (0.5).
        #expect(store.topKeys(limit: 2, at: now.addingTimeInterval(200)) == ["b", "a"])
        #expect(store.score(for: "missing", at: now) == 0)
    }

    @Test func frecencyPersists() throws {
        let persistence = InMemoryFrecencyPersistence()
        let model = PaletteModel(persistence: persistence)
        let provider = StaticPaletteProvider(id: "p", items: [
            PaletteItem(id: "x", title: "X", primary: PaletteCommand(id: "run", title: "Run", effect: .perform {})),
        ])
        model.reset(to: PalettePageSpec(id: "root", title: "Root", placeholder: "", providers: [provider]))
        model.handle(.submit)
        let stored = try #require(persistence.stored)
        #expect(stored.score(for: "x", at: Date()) > 0.9)
    }

    @Test func incrementalSearchMatchesFullScan() {
        let incremental = catalogIndex()
        _ = incremental.matches(for: FuzzyQuery("s"))
        _ = incremental.matches(for: FuzzyQuery("sp"))
        let narrowed = incremental.matches(for: FuzzyQuery("spl r")).map(\.index)
        let fresh = catalogIndex().matches(for: FuzzyQuery("spl r")).map(\.index)
        #expect(narrowed == fresh)
        #expect(!narrowed.isEmpty)
        // Backspacing (not a refinement) rescans everything.
        let widened = incremental.matches(for: FuzzyQuery("sp")).map(\.index)
        #expect(widened == catalogIndex().matches(for: FuzzyQuery("sp")).map(\.index))
    }

    @Test func emptyQueryShowsRecentThenSectionsInOrder() {
        let registry = ActionRegistry.standard()
        let workspaces = StaticPaletteProvider(id: "ws", items: [
            PaletteItem(id: "workspace:1", title: "api server", primary: PaletteCommand(id: "go", title: "Go", effect: .perform {})),
        ], showsItemsForEmptyQuery: false)
        let registryItems = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        let index = PaletteSearchIndex(
            items: registryItems + (workspaces.immediateItems ?? []),
            visibleWhenQueryEmpty: Array(repeating: true, count: registryItems.count) + [false]
        )
        var frecency = FrecencyStore()
        frecency.record("action:splitDown", at: now)
        let sections = PaletteRanker.rank(index: index, query: "", frecency: frecency, now: now, showsRecent: true)
        #expect(sections.first?.id == "recent")
        #expect(sections.first?.rows.map(\.id) == ["action:splitDown"])
        #expect(sections.dropFirst().first?.id == "category.window")
        let all = sections.flatMap(\.rows).map(\.id)
        #expect(!all.contains("workspace:1"))
        #expect(Set(all).count == all.count)

        let typed = PaletteRanker.rank(index: index, query: "api", frecency: frecency, now: now, showsRecent: true)
        #expect(typed.flatMap(\.rows).contains { $0.id == "workspace:1" })
    }
}
