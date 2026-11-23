@testable import CmuxNextAgentPane
import Observation
import Testing

/// The native New Tab page (Lawrence 2026-10-29: "make the new tab page in swift"): the dropdown's
/// rows for the typed text, every Commands palette action reachable, and what Return and a pick run.
@MainActor
struct NativeNewTabModelTests {
    private static func page(actions: Int = 300) -> AgentPaneNewTab {
        let omnibar = AgentPaneOmnibar(
            tabs: [AgentPaneOmnibar.Tab(id: "t1", kind: .browser, title: "Vite guide", detail: "vite.dev/guide", workspace: "web")],
            workspaces: [AgentPaneOmnibar.Workspace(id: "w1", name: "app-efficiency")],
            actions: [AgentPaneOmnibar.Action(id: "toggleSidebar", title: "Toggle Sidebar", detail: "View", keycaps: ["⌘", "B"])]
                + (0..<actions).map { AgentPaneOmnibar.Action(id: "action.\($0)", title: "Action number \($0)") },
            history: [AgentPaneOmnibar.Page(url: "https://news.ycombinator.com/", title: "Hacker News")]
        )
        return AgentPaneNewTab(kind: .agent, omnibar: omnibar)
    }

    @Test func theEmptyFieldListsWhereYouCanGo() {
        let rows = NativeNewTabRanker().rows(for: " ", kind: .agent, omnibar: Self.page().omnibar)
        #expect(rows.map(\.id) == ["tab:t1", "workspace:w1"])
    }

    @Test func typedTextLeadsWithTheKindsRowThenMatches() {
        let ranker = NativeNewTabRanker()
        let omnibar = Self.page().omnibar
        #expect(ranker.rows(for: "vite", kind: .agent, omnibar: omnibar).map(\.id) == ["ask", "tab:t1"])
        #expect(ranker.rows(for: "vite", kind: .terminal, omnibar: omnibar).first == .run("vite"))
        #expect(ranker.rows(for: "hacker", kind: .browser, omnibar: omnibar).map(\.id) == ["open", "page:https://news.ycombinator.com/"])
    }

    @Test func bookmarkWebsiteRowsKeepTheirFaviconAndFixedIdentity() throws {
        var page = Self.page()
        page.omnibar.bookmarks = [AgentPaneOmnibar.Page(url: "https://swift.org/", title: "Swift",
                                                        icon: "data:image/png;base64,AAAA")]
        let row = try #require(NativeNewTabRanker().rows(for: "swift", kind: .browser, omnibar: page.omnibar).last)
        guard case .bookmark(let bookmark) = row else { Issue.record("the matching bookmark was not ranked as a bookmark"); return }
        #expect(bookmark.icon == "data:image/png;base64,AAAA")
        #expect(row.id == "bookmark:https://swift.org/")
        let content = NativeNewTabRowContent(row, strings: NativeNewTabStrings())
        #expect(content.icon == bookmark.icon)
    }

    @Test func faviconRefreshChangesOnlyTheHostSnapshot() {
        var page = Self.page()
        page.omnibar.history = [AgentPaneOmnibar.Page(url: "https://swift.org/", title: "Swift")]
        let model = NativeNewTabModel(page: page, actions: NativeNewTabActions(), favicons: NativeNewTabFavicons(revision: { 0 }, page: { current in
            var refreshed = current
            refreshed.omnibar.history[0].icon = "data:image/png;base64,AAAA"
            return refreshed
        }))
        model.refreshFaviconPage()
        #expect(model.page.omnibar.history[0].icon == "data:image/png;base64,AAAA")
        #expect(model.text.isEmpty)
    }

    @Test func thePalettesActionsAreAskedForOnceAtTheFirstKeystrokeAndComeLater() {
        var empty = Self.page()
        empty.omnibar.actions = []
        var asks: [@MainActor ([AgentPaneOmnibar.Action]) -> Void] = []
        let model = NativeNewTabModel(page: empty, actions: NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }, action: { _, _ in }),
                                      paletteActions: { _, deliver in asks.append(deliver) })
        #expect(asks.isEmpty, "the page shows before the palette's actions are listed")
        model.text = "toggle side"
        #expect(asks.count == 1)
        // The keystroke's turn reads nothing: the rows have no action until the list comes.
        #expect(!model.rows.contains { $0.id == "action:toggleSidebar" })
        asks[0](Self.page().omnibar.actions)
        #expect(model.rows.contains { $0.id == "action:toggleSidebar" })
        model.text = "toggle"
        model.loadPaletteActions()
        #expect(asks.count == 1, "asked once per page")
    }

    @Test func anAdoptedPageDropsTheEarlierPagesLateActions() {
        var empty = Self.page()
        empty.omnibar.actions = []
        var asks: [@MainActor ([AgentPaneOmnibar.Action]) -> Void] = []
        let actions = NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }, action: { _, _ in })
        let model = NativeNewTabModel(page: empty, actions: actions, paletteActions: { _, deliver in asks.append(deliver) })
        model.loadPaletteActions()
        model.adopt(page: empty, actions: actions, paletteActions: { _, deliver in asks.append(deliver) })
        asks[0](Self.page().omnibar.actions)
        #expect(model.page.omnibar.actions.isEmpty, "the earlier page's answer reached the adopted page")
        model.loadPaletteActions()
        asks[1](Self.page().omnibar.actions)
        #expect(!model.page.omnibar.actions.isEmpty)
    }

    /// The palette's actions read again at the page's first use: an equal list changes nothing; a list that differs
    /// changes the rows in one update, and the highlighted row stays the same row, by its id, while the rows have it.
    @Test func aListReadAgainKeepsTheHighlightedRowByItsID() throws {
        var asks: [@MainActor ([AgentPaneOmnibar.Action]) -> Void] = []
        let listed = Self.page(actions: 3).omnibar.actions
        let model = NativeNewTabModel(page: Self.page(actions: 3), actions: NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }, action: { _, _ in }),
                                      paletteRefresh: { _, deliver in asks.append(deliver) })
        model.text = "action number"
        model.text = "action number "
        try #require(asks.count == 1, "the page asks for the actions again once, at its first letter: \(asks.count) asks")
        // The first and the last action row: the highlight goes on the last one.
        let rows = model.rows.map(\.id)
        let actionRows = rows.indices.filter { rows[$0].hasPrefix("action:") }
        let above = try #require(actionRows.first, "no action row: \(rows)")
        let at = try #require(actionRows.last, "no action row: \(rows)")
        try #require(above < at, "one action row only: \(rows)")
        let (aboveID, atID) = (String(rows[above].dropFirst("action:".count)), String(rows[at].dropFirst("action:".count)))
        model.highlighted = at

        let change = Change()
        withObservationTracking { _ = model.page } onChange: {
            MainActor.assumeIsolated { change.seen = true } // main-proof: the model is main-actor state, set by this row
        }
        asks[0](listed)
        #expect(!change.seen && model.highlighted == at, "an equal list changed the page")

        // A row above the highlighted one is gone: the highlight follows its row.
        asks[0](listed.filter { $0.id != aboveID })
        #expect(model.selectedIndex.map { model.rows[$0].id } == rows[at], "the highlight left its row: \(model.rows.map(\.id)), highlighted \(String(describing: model.highlighted))")
        #expect(model.highlighted == at - 1, "the row above did not go away: \(model.rows.map(\.id))")
        // The highlighted row is gone: Return goes back to the first row.
        asks[0](listed.filter { $0.id != aboveID && $0.id != atID })
        #expect(model.highlighted == nil, "the highlight stayed at \(String(describing: model.highlighted)) with its row gone")
    }

    /// A run of a row that is no palette action asks for no list: the page goes away with the run. A run of an action
    /// row is a first use of the page: it asks for the actions again.
    @Test func onlyARunOfAnActionRowAsksForTheActionsAgain() throws {
        var asks = 0
        let model = NativeNewTabModel(page: Self.page(actions: 3), actions: NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }),
                                      paletteRefresh: { _, _ in asks += 1 })
        model.activate(.run("ls"))
        #expect(asks == 0, "a run of a terminal row asked for the palette's actions \(asks) times")
        let action = try #require(model.page.omnibar.actions.first, "the page has no action")
        model.activate(.action(action))
        #expect(asks == 1, "a run of an action row asked for the palette's actions \(asks) times where 1 is wanted")
    }

    @Test func everyPaletteActionIsReachable() {
        let omnibar = Self.page().omnibar
        #expect(omnibar.actions.count == 301, "the 40-entry cap no longer drops palette actions")
        let rows = NativeNewTabRanker().rows(for: "number 299", kind: .agent, omnibar: omnibar)
        #expect(rows.map(\.id) == ["ask", "action:action.299"])
        let sidebar = NativeNewTabRanker().rows(for: "side", kind: .agent, omnibar: omnibar)
        #expect(sidebar.contains(.action(omnibar.actions[0])))
    }

    @Test func returnAndPicksRunThroughTheActions() {
        var log: [String] = []
        let actions = NativeNewTabActions(
            submit: { text, kind, search in log.append("submit \(kind.rawValue) \(text) \(search)") },
            jump: { target, id in log.append("jump \(target.rawValue) \(id)") },
            action: { id, shown in log.append("action \(id) shown as \(shown)") }
        )
        let model = NativeNewTabModel(page: Self.page(), actions: actions)
        model.commit()
        model.text = "toggle side"
        model.commit()
        model.move(1)
        model.commit()
        model.text = "vite"
        model.move(-1)
        model.commit()
        #expect(log == [
            "submit agent  false",
            "submit agent toggle side false",
            "action toggleSidebar shown as Toggle Sidebar",
            "jump tab t1",
        ])
    }

    @Test func aKeystrokeRanksThePalettesActionsFast() {
        let omnibar = Self.page(actions: 1000).omnibar
        let ranker = NativeNewTabRanker()
        let clock = ContinuousClock()
        let elapsed = clock.measure { for text in ["t", "to", "tog", "togg", "toggle"] { _ = ranker.rows(for: text, kind: .agent, omnibar: omnibar) } }
        print("native-new-tab: 5 keystrokes over 1000 actions took \(elapsed)")
        #expect(elapsed < .milliseconds(50))
    }
}

/// Whether an observed value changed.
@MainActor private final class Change {
    var seen = false
}
