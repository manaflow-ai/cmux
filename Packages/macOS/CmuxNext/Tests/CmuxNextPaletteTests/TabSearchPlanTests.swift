import CmuxNextPalette
import Foundation
import Testing

/// Search Tabs rows and ranking (pure): order, sections, visibility and
/// which fields a query matches.
@Suite struct TabSearchPlanTests {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    var sample: [TabSearchEntry] { MockTabSearchSource.sample(now: now) }

    func ids(_ rows: [TabSearchRow]) -> [String] { rows.map(\.entry.id) }

    @Test func recentListsCurrentThenMostRecentThenClosedNewestFirst() {
        let rows = TabSearchPlan.rows(sample, style: .recent, now: now)
        #expect(ids(rows) == ["tab_1", "tab_2", "tab_3", "tab_4", "tab_5", "tab_6", "local/tab_7", "local/tab_8"])
        #expect(rows.prefix(6).allSatisfy { $0.section.id == "tabSearch.open" })
        #expect(rows.suffix(2).allSatisfy { $0.section.id == "tabSearch.closed" && $0.section.order == TabSearchSection.closedOrder })
        // Return on the first open switches back to the tab used before.
        #expect(TabSearchPlan.emptyQuerySelection(rows) == 1)
        // Recency boosts typed queries, newest most; closed tabs get none.
        #expect(rows[1].rankBias > rows[3].rankBias)
        #expect(rows.suffix(2).allSatisfy { $0.rankBias == 0 })
    }

    @Test func rowsCarryTheirPlaceWorkspaceMachineAndProcess() {
        let rows = TabSearchPlan.rows(sample, style: .recent, now: now)
        let page = rows.first { $0.entry.id == "tab_2" }!
        #expect(page.subtitle == "github.com · api")
        #expect(page.keywords.contains("https://github.com/manaflow-ai/cmux/pulls"))
        let remote = rows.first { $0.entry.id == "tab_5" }!
        #expect(remote.subtitle == "/home/dev/cmux-tui · build box · mac-mini · Window 2")
        #expect(remote.accessory == "cargo")
        #expect(rows.first?.accessory != nil)
    }

    @Test func aTabClosedThisSecondNeverReadsAsFuture() {
        let entries = [TabSearchEntry(id: "c", kind: .terminal, title: "x", order: 0, state: .closed(closedAt: now.addingTimeInterval(0.4)))]
        let accessory = TabSearchPlan.rows(entries, style: .recent, now: now).first?.accessory ?? ""
        #expect(!accessory.isEmpty)
        #expect(!accessory.hasPrefix("in "))
    }

    @Test func groupedKeepsLayoutOrderUnderWindowAndWorkspace() {
        let rows = TabSearchPlan.rows(sample, style: .grouped, now: now)
        let open = rows.filter { !$0.entry.isClosed }
        #expect(ids(open) == ["tab_1", "tab_2", "tab_3", "tab_4", "tab_5", "tab_6"])
        let titles = open.map(\.section.title)
        #expect(titles == ["api", "api", "web", "web", "Window 2 · build box · mac-mini", "Window 2 · build box"])
        #expect(open.map(\.section.order) == [0, 0, 1, 1, 2, 3])
        #expect(rows.last?.section.order == TabSearchSection.closedOrder)
    }

    @Test func compactShowsFolderNamesAndFewerClosedTabs() {
        var entries = sample
        for index in 0..<8 {
            entries.append(TabSearchEntry(id: "closed-\(index)", kind: .terminal, title: "old \(index)", order: 100 + index,
                                          state: .closed(closedAt: now.addingTimeInterval(-3600 - Double(index)))))
        }
        let compact = TabSearchPlan.rows(entries, style: .compact, now: now)
        #expect(compact.filter { $0.entry.isClosed && $0.isVisibleWhenQueryEmpty }.count == TabSearchPlan.closedListedCompact)
        #expect(compact.first { $0.entry.id == "tab_3" }?.subtitle == "web")
        #expect(compact.first { $0.entry.id == "tab_3" }?.accessory == nil)
        let recent = TabSearchPlan.rows(entries, style: .recent, now: now)
        #expect(recent.filter { $0.entry.isClosed && $0.isVisibleWhenQueryEmpty }.count == 10)
        #expect(recent.filter(\.entry.isClosed).count == 10)
    }

    @Test func queriesMatchTitleURLFolderAndProcess() {
        func top(_ query: String) -> String? {
            TabSearchRanker.search(sample, query: query, now: now).first?.row.entry.id
        }
        #expect(top("pull requests") == "tab_2")
        #expect(top("github") == "tab_2")
        #expect(top("localhost") == "tab_4")
        #expect(top("src/web") == "tab_3")
        #expect(top("cargo") == "tab_5")
        #expect(top("mac-mini") == "tab_5")
        // Closed tabs stay below every open match, even a weak one.
        let htop = TabSearchRanker.search(sample, query: "htop", now: now)
        #expect(htop.first { $0.row.entry.isClosed }?.row.entry.id == "local/tab_8")
    }

    @Test func closedTabsStayBelowOpenTabsForEveryQuery() {
        // "api" matches the closed htop tab's folder and the open tabs'
        // workspace; open tabs still come first.
        let matches = TabSearchRanker.search(sample, query: "api", now: now)
        let firstClosed = matches.firstIndex { $0.row.entry.isClosed } ?? matches.count
        #expect(matches.prefix(firstClosed).allSatisfy { !$0.row.entry.isClosed })
        #expect(matches.suffix(from: firstClosed).allSatisfy { $0.row.entry.isClosed })
        #expect(matches.contains { $0.row.entry.id == "local/tab_8" })
        let openOnly = TabSearchRanker.search(sample, query: "api", includeClosed: false, now: now)
        #expect(!openOnly.contains { $0.row.entry.isClosed })
        #expect(TabSearchRanker.search(sample, query: "", limit: 3, now: now).count == 3)
    }

    /// Seeded random tab sets: every open tab is listed exactly once, open
    /// rows precede closed rows, at most `closedListed` closed rows show
    /// before typing, and for any query the ranked results keep that order.
    @Test(arguments: 0..<40)
    func invariantsHoldForRandomTabSets(seed: Int) {
        var random = SplitMix(seed: UInt64(seed))
        let words = ["api", "web", "git", "log", "dev", "test", "zsh", "vim", "docs", "build"]
        var entries: [TabSearchEntry] = []
        let count = Int(random.next() % 40)
        for index in 0..<count {
            let closed = random.next() % 3 == 0
            let word = words[Int(random.next() % UInt64(words.count))]
            let date = now.addingTimeInterval(-Double(random.next() % 10_000))
            entries.append(TabSearchEntry(
                id: "t\(index)", kind: random.next() % 2 == 0 ? .terminal : .browser, title: "\(word) \(index)",
                url: random.next() % 2 == 0 ? "https://\(word).example.com/\(index)" : nil, cwd: "/src/\(word)",
                workspaceID: "ws\(random.next() % 4)", workspaceTitle: word, order: index,
                state: closed ? .closed(closedAt: date) : .open(isCurrent: false, lastActive: random.next() % 4 == 0 ? nil : date)))
        }
        for style in TabSearchStyle.allCases {
            let rows = TabSearchPlan.rows(entries, style: style, now: now)
            let openIDs = entries.filter { !$0.isClosed }.map(\.id)
            #expect(rows.filter { !$0.entry.isClosed }.map(\.entry.id).sorted() == openIDs.sorted())
            let firstClosed = rows.firstIndex { $0.entry.isClosed } ?? rows.count
            #expect(rows.suffix(from: firstClosed).allSatisfy { $0.entry.isClosed })
            #expect(rows.filter { $0.entry.isClosed && $0.isVisibleWhenQueryEmpty }.count <= TabSearchPlan.closedListed)
            for query in ["", words[seed % words.count], "example", "src"] {
                let matches = TabSearchRanker.search(entries, query: query, style: style, now: now)
                let split = matches.firstIndex { $0.row.entry.isClosed } ?? matches.count
                #expect(matches.suffix(from: split).allSatisfy { $0.row.entry.isClosed }, "style \(style) query \(query)")
                #expect(Set(matches.map(\.row.entry.id)).count == matches.count)
            }
        }
    }
}

/// Deterministic generator for the seeded tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
