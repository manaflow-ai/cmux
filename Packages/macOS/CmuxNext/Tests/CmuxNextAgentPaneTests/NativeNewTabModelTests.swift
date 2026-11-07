@testable import CmuxNextAgentPane
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

    @Test func thePalettesActionsAreAskedForOnceAtTheFirstKeystrokeAndComeLater() {
        var empty = Self.page()
        empty.omnibar.actions = []
        var asks: [@MainActor ([AgentPaneOmnibar.Action]) -> Void] = []
        let model = NativeNewTabModel(page: empty, actions: NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }, action: { _ in }),
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
        let actions = NativeNewTabActions(submit: { _, _, _ in }, jump: { _, _ in }, action: { _ in })
        let model = NativeNewTabModel(page: empty, actions: actions, paletteActions: { _, deliver in asks.append(deliver) })
        model.loadPaletteActions()
        model.adopt(page: empty, actions: actions, paletteActions: { _, deliver in asks.append(deliver) })
        asks[0](Self.page().omnibar.actions)
        #expect(model.page.omnibar.actions.isEmpty, "the earlier page's answer reached the adopted page")
        model.loadPaletteActions()
        asks[1](Self.page().omnibar.actions)
        #expect(!model.page.omnibar.actions.isEmpty)
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
            action: { id in log.append("action \(id)") }
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
            "action toggleSidebar",
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
