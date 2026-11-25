@testable import CmuxNextBrowser
import Foundation
import Testing

/// The open-tab index of the omnibar (`OmniboxLocalIndex.setOpenTab` / `removeOpenTab`, Switch to Tab rows), kept by
/// tab events instead of a list rebuilt on every key (HOT PATH AUDIT browser, AUDIT row 6).
struct OmniboxOpenTabIndexTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func tab(_ key: String, _ url: String, _ title: String) -> OmniboxTabRow {
        OmniboxTabRow(key: key, url: URL(string: url)!, title: title)
    }

    /// The Switch to Tab rows for `text`: tab key and score, in row order.
    private static func rows(_ index: OmniboxLocalIndex, _ text: String, asking: String? = nil) async -> [(key: String, score: Double)] {
        let gate = OmniboxGenerationGate()
        gate.begin(1)
        let query = OmniboxLocalQuery(generation: 1, gate: gate, text: text, resolver: OmniboxResolver(), maxRows: 12,
                                      sources: [.tabs], excludedTab: asking, now: start)
        let rows = await index.run(query) ?? []
        return rows.filter { $0.kind == .switchToTab }.compactMap { row in row.tabKey.map { ($0, row.score) } }
    }

    /// A tab's rank does not depend on when it, or another tab, last changed: a tab navigated a week ago and one
    /// changed now score the same for the same kind of match, in either order of their changes.
    @Test func tabRowsRankByTheirMatchNotByWhenTheyChanged() async {
        var orders: [[String]] = []
        for weekOldFirst in [true, false] {
            let index = OmniboxLocalIndex()
            let old = Self.tab("tab-a", "https://alpha.example/a", "Report alpha")
            let new = Self.tab("tab-b", "https://alpha.example/b", "Report alpha")
            if weekOldFirst {
                await index.setOpenTab(old, now: Self.start.addingTimeInterval(-7 * 86_400))
                await index.setOpenTab(new, now: Self.start)
            } else {
                await index.setOpenTab(new, now: Self.start)
                await index.setOpenTab(old, now: Self.start.addingTimeInterval(-7 * 86_400))
            }
            let rows = await Self.rows(index, "report")
            #expect(rows.count == 2)
            #expect(Set(rows.map(\.score)).count == 1, "equal matches scored \(rows.map(\.score))")
            orders.append(rows.map(\.key))
        }
        #expect(orders[0] == orders[1], "the order of the tabs' changes moved their rank: \(orders)")
    }

    /// Two tabs on one URL: the row names the first by key; when it closes, the row names the second.
    @Test func aURLsRowFollowsItsRemainingTab() async {
        let index = OmniboxLocalIndex()
        await index.setOpenTab(Self.tab("tab-1", "https://docs.example/x", "Docs"), now: Self.start)
        await index.setOpenTab(Self.tab("tab-2", "https://docs.example/x", "Docs"), now: Self.start)
        #expect(await Self.rows(index, "docs").map(\.key) == ["tab-1"])
        await index.removeOpenTab("tab-1", now: Self.start)
        #expect(await Self.rows(index, "docs").map(\.key) == ["tab-2"])
        await index.removeOpenTab("tab-2", now: Self.start)
        #expect(await Self.rows(index, "docs").isEmpty)
    }

    /// The asking tab is never its own row: on a URL another tab also has, the row names the other tab; alone on a URL,
    /// it takes no Switch to Tab slot from the other matches.
    @Test func theAskingTabIsNeverItsOwnRowAndTakesNoSlot() async {
        let index = OmniboxLocalIndex()
        await index.setOpenTab(Self.tab("tab-1", "https://news.example/", "News"), now: Self.start)
        await index.setOpenTab(Self.tab("tab-2", "https://news.example/", "News"), now: Self.start)
        #expect(await Self.rows(index, "news", asking: "tab-1").map(\.key) == ["tab-2"])

        let crowded = OmniboxLocalIndex()
        for number in 1...4 {
            await crowded.setOpenTab(Self.tab("tab-\(number)", "https://shop\(number).example/", "Shop \(number)"), now: Self.start)
        }
        let rows = await Self.rows(crowded, "shop", asking: "tab-1")
        #expect(rows.count == OmniboxPhaseA.tabLimit, "\(rows.count) Switch to Tab rows; the asking tab took a slot")
        #expect(!rows.contains { $0.key == "tab-1" })
    }
}
