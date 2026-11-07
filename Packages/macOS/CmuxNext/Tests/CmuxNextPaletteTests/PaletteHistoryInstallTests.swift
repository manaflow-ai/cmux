@testable import CmuxNextPalette
import Foundation
import Testing

/// The ranker holds the usage history of one ``FrecencyStore/revision`` and a keystroke names it
/// instead of resending it. The order must be the one the resent history gives, and a change to
/// the history (a new use) must reach the very next rank, never an older installed copy.
@MainActor
@Suite(.paletteRanker)
struct PaletteHistoryInstallTests {
    @MainActor private final class Workspaces: PaletteWorkspaceSource {
        var workspaces: [PaletteWorkspace]
        init(_ workspaces: [PaletteWorkspace]) { self.workspaces = workspaces }
        func selectWorkspace(id: String) {}
        func renameWorkspace(id: String, to title: String) {}
        func closeWorkspace(id: String) {}
    }

    private static func index() -> PaletteSearchIndex {
        let provider = WorkspacePaletteProvider(source: Workspaces([
            PaletteWorkspace(id: "w0", title: "api server", directory: "~/fun/api"),
            PaletteWorkspace(id: "w1", title: "api worker", directory: "~/fun/api"),
            PaletteWorkspace(id: "w2", title: "api client", directory: "~/fun/api"),
        ]), showsItemsForEmptyQuery: true)
        return PaletteSearchIndex(items: provider.makeItems())
    }

    private static func order(_ ranker: PaletteRanker, _ index: inout PaletteSearchIndex, _ query: String,
                              _ frecency: FrecencyStore, now: Date, sendsHistory: Bool) -> [String] {
        ranker.rank(index: &index, version: 1, query: query, sectionOrders: [], frecency: frecency, now: now,
                    showsRecent: true, sendsHistory: sendsHistory)
            .flatMap(\.rows).map { index.entries[$0.index].title }
    }

    @Test func anInstalledHistoryRanksLikeTheResentOneAndFollowsEveryChange() {
        let now = Date()
        let ranker = PaletteRanker()
        var index = Self.index()
        var frecency = FrecencyStore()
        frecency.record("workspace:w2", at: now)
        frecency.recordPick("workspace:w2", query: "api c", at: now)
        frecency.recordPick("workspace:w2", query: "api c", at: now)
        for query in ["api", "api c", "a"] {
            #expect(Self.order(ranker, &index, query, frecency, now: now, sendsHistory: false)
                == Self.order(ranker, &index, query, frecency, now: now, sendsHistory: true), "\(query)")
        }
        #expect(Self.order(ranker, &index, "api", frecency, now: now, sendsHistory: false).first == "api client")

        // New uses of api worker: the next rank reads them, with no resend asked for. "er" has no
        // learned pick, so only use decides between api server and api worker.
        let staleOrder = Self.order(ranker, &index, "er", frecency, now: now, sendsHistory: false)
        let before = frecency.revision
        for minute in 1...6 { frecency.record("workspace:w1", at: now.addingTimeInterval(Double(minute) * 60)) }
        #expect(frecency.revision != before)
        let later = now.addingTimeInterval(600)
        let fresh = Self.order(ranker, &index, "er", frecency, now: later, sendsHistory: false)
        #expect(fresh == Self.order(ranker, &index, "er", frecency, now: later, sendsHistory: true))
        #expect(fresh.first == "api worker", "\(staleOrder) -> \(fresh)")
    }

    @Test func aSavedHistoryKeepsItsContentButNotItsRevision() throws {
        var frecency = FrecencyStore()
        #expect(frecency.revision == 0)
        frecency.record("workspace:w0", at: Date())
        let copy = try JSONDecoder().decode(FrecencyStore.self, from: JSONEncoder().encode(frecency))
        #expect(copy == frecency)
        #expect(copy.revision != 0)
    }
}
