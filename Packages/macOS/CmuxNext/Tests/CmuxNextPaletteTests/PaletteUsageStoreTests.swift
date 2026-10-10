import CmuxNextActions
import CmuxNextPalette
import Foundation
import Testing

/// The palette sends each run to its usage store with the typed query
/// (learned picks, palette-ranking.md 5.2) and ranks with the store's
/// history; the store, not the palette, owns the history.
@MainActor
@Suite(.paletteRanker) struct PaletteUsageStoreTests {
    final class RecordingStore: PaletteUsageStore {
        var history = FrecencyStore()
        var onChange: (@MainActor () -> Void)?
        var recorded: [(key: String, query: String)] = []
        var prepared = 0

        func recordUse(key: String, query: String, at now: Date) {
            recorded.append((key, query))
        }

        func prepare() {
            prepared += 1
        }

        var canHideRows = true
        var hiddenCalls: [(key: String, hidden: Bool)] = []
        var forgotten: [String] = []

        func setHidden(key: String, hidden: Bool) {
            hiddenCalls.append((key, hidden))
        }

        func forget(key: String) {
            forgotten.append(key)
        }
    }

    @Test func aRunSendsItsKeyAndQueryAndAStoreChangeReachesTheRanker() {
        let store = RecordingStore()
        let model = PaletteModel(usage: store)
        var ran = false
        let item = PaletteItem(id: "action:splitRight", title: "Split Right",
                               primary: PaletteCommand(id: "run", title: "Run", effect: .perform { ran = true }),
                               frecencyKey: "action:splitRight")
        model.reset(to: PalettePageSpec(id: "test", title: "Test", placeholder: "", symbol: "command",
                                   providers: [StaticPaletteProvider(id: "rows", items: [item])]))
        model.query = "Sp"
        model.run(item.primary, of: item)
        #expect(ran)
        #expect(store.recorded.map(\.key) == ["action:splitRight"])
        #expect(store.recorded.map(\.query) == ["Sp"])
        var history = FrecencyStore()
        history.replace(entries: ["action:splitRight": FrecencyStore.Entry(score: 3, lastUsed: .now)],
                        picks: [FrecencyStore.Pick(prefix: "sp", key: "action:splitRight", score: 3, lastUsed: .now, isLast: true)],
                        halfLife: history.halfLife, pickHalfLife: history.pickHalfLife)
        store.history = history
        store.onChange?()
        #expect(model.frecency.picks.map(\.key) == ["action:splitRight"])
    }

    /// Learned picks reach the shared ranker through the native bridge (only
    /// the picks whose start begins the query are sent) and lift their row.
    @Test func aLearnedPickLiftsItsRowThroughTheBridge() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func item(_ id: String, _ title: String) -> PaletteItem {
            PaletteItem(id: id, title: title, primary: PaletteCommand(id: "run", title: "Run", effect: .perform {}), frecencyKey: id)
        }
        let items = [item("action:splitRight", "Split Right"), item("action:splitBrowserRight", "Split Browser Right")]
        var index = PaletteSearchIndex(items: items)
        let ranker = PaletteRanker()
        func top(_ query: String, _ frecency: FrecencyStore) -> String? {
            ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now, showsRecent: false)
                .flatMap(\.rows).first.map { items[$0.index].id }
        }
        var history = FrecencyStore()
        #expect(top("spl", history) == "action:splitRight")
        history.replace(entries: [:],
                        picks: [FrecencyStore.Pick(prefix: "sp", key: "action:splitBrowserRight", score: 1, lastUsed: now, isLast: true),
                                FrecencyStore.Pick(prefix: "x", key: "action:splitRight", score: 9, lastUsed: now, isLast: true)],
                        halfLife: history.halfLife, pickHalfLife: history.pickHalfLife)
        #expect(top("spl", history) == "action:splitBrowserRight")
        #expect(top("Split  B", history) == "action:splitBrowserRight")
    }

    @Test func aLocalStoreKeepsTheFormerHistoryWithoutPicks() {
        let persistence = InMemoryFrecencyPersistence()
        let store = LocalPaletteUsageStore(persistence: persistence)
        store.recordUse(key: "action:newColumn", query: "new", at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(persistence.stored?.entries["action:newColumn"]?.score == 1)
        #expect(store.history.picks.isEmpty)
        let reloaded = try? JSONDecoder().decode(FrecencyStore.self, from: JSONEncoder().encode(store.history))
        #expect(reloaded?.entries.keys.sorted() == ["action:newColumn"])
    }
}
