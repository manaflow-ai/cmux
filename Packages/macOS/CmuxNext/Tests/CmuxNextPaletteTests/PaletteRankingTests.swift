import CmuxNextActions
import CmuxNextPalette
import Foundation
import Testing

@Suite struct PaletteRankingTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Items plus their index, so ranked entry indices map back to item IDs.
    struct Corpus {
        let items: [PaletteItem]
        var index: PaletteSearchIndex
        let ranker: PaletteRanker

        init(_ items: [PaletteItem], visible: [Bool]? = nil) {
            self.items = items
            index = PaletteSearchIndex(items: items, visibleWhenQueryEmpty: visible)
            ranker = PaletteRanker()
        }

        mutating func rank(_ query: String, frecency: FrecencyStore, now: Date, showsRecent: Bool = false) -> [(section: Int?, ids: [String])] {
            ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now, showsRecent: showsRecent)
                .map { section in (section.sectionIndex, section.rows.map { items[$0.index].id }) }
        }

        mutating func topID(_ query: String, frecency: FrecencyStore, now: Date) -> String? {
            ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now, showsRecent: false)
                .flatMap(\.rows)
                .max { $0.score < $1.score }
                .map { items[$0.index].id }
        }
    }

    func catalogIndex() -> Corpus {
        Corpus(RegistryPaletteProvider(registry: .standard(), includeUnbound: true).makeItems())
    }

    func topID(_ query: String, index: Corpus, frecency: FrecencyStore = FrecencyStore()) -> String? {
        var index = index
        return index.topID(query, frecency: frecency, now: now)
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
        let index = Corpus(KeyboardShortcutsPaletteProvider(registry: registry).makeItems())
        #expect(topID("⇧⌘P", index: index) == "shortcut:commandPalette")
        var corpus = index
        let top = corpus.rank("cmd d split", frecency: FrecencyStore(), now: now).flatMap(\.ids).prefix(3)
        #expect(top.contains("shortcut:splitRight"))
        // Every catalog action with a default shortcut, label or chord (the
        // Cmd-J leader's) is listed.
        let expected = ActionCatalog.all.filter { $0.defaultShortcut != nil || $0.shortcutLabel != nil || $0.defaultChord != nil }.count
        #expect(index.items.count == expected)
    }

    @Test func frecencyBreaksTiesButDoesNotBeatClearlyBetterMatches() {
        func item(_ id: String, _ title: String) -> PaletteItem {
            PaletteItem(id: id, title: title, primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}))
        }
        let index = Corpus([
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
        var incremental = catalogIndex().index
        _ = incremental.matches(for: FuzzyQuery("s"))
        _ = incremental.matches(for: FuzzyQuery("sp"))
        let narrowed = incremental.matches(for: FuzzyQuery("spl r")).map(\.index)
        var fresh = catalogIndex().index
        #expect(narrowed == fresh.matches(for: FuzzyQuery("spl r")).map(\.index))
        #expect(!narrowed.isEmpty)
        // Backspacing (not a refinement) rescans everything.
        let widened = incremental.matches(for: FuzzyQuery("sp")).map(\.index)
        var again = catalogIndex().index
        #expect(widened == again.matches(for: FuzzyQuery("sp")).map(\.index))
    }

    @Test func emptyQueryShowsRecentThenSectionsInOrder() {
        let registry = ActionRegistry.standard()
        registry.bind("splitDown") {}
        let workspace = PaletteItem(
            id: "workspace:1", title: "api server",
            section: PaletteSection(id: "ws", title: "Workspaces", order: 10),
            primary: PaletteCommand(id: "go", title: "Go", effect: .perform {})
        )
        let registryItems = RegistryPaletteProvider(registry: registry, includeUnbound: true).makeItems()
        var corpus = Corpus(registryItems + [workspace], visible: Array(repeating: true, count: registryItems.count) + [false])
        var frecency = FrecencyStore()
        frecency.record("action:splitDown", at: now)
        let sections = corpus.rank("", frecency: frecency, now: now, showsRecent: true)
        #expect(sections.first?.section == nil)
        #expect(sections.first?.ids == ["action:splitDown"])
        let all = sections.flatMap(\.ids)
        #expect(all.dropFirst().first == "action:openSettings")
        #expect(!all.contains("workspace:1"))
        #expect(Set(all).count == all.count)

        let typed = corpus.rank("api", frecency: frecency, now: now, showsRecent: true)
        #expect(typed.flatMap(\.ids).contains("workspace:1"))
    }
}
