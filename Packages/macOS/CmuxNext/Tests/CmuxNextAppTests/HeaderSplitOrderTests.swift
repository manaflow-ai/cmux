import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's Terminal and Browser buttons (cx-qom0): the panes they open line up right of
/// the chat in the order they were opened, and each button still toggles its own pane. Runs the
/// header's split path against a store whose layout the split actions change as the daemon would.
@MainActor
struct HeaderSplitOrderTests {
    /// A workspace whose screen is one row of panes, left to right; each pane holds one tab.
    final class Row {
        let store = DaemonStore()
        let registry = ActionRegistry()
        private(set) var panes: [(pane: PaneID, surface: SurfaceID, kind: TabKind)] = [(1, 1, .other("agentChat"))]
        private var next: UInt64 = 2
        /// The page each page tab shows (the diff viewer's `diff`), by surface.
        private(set) var pages: [SurfaceID: String] = [:]
        /// The last invocation of each action the row handles.
        private(set) var invocations: [String: ActionInvocation] = [:]
        /// The chat's folder.
        let cwd = "/repo"

        static func id(_ surface: SurfaceID) -> String { "surface:\(surface.rawValue)" }
        var chat: String { Self.id(1) }
        /// The row's tab ids left to right.
        var tabs: [String] { panes.map { Self.id($0.surface) } }
        /// The row's tabs left to right, by kind.
        var order: [String] {
            panes.map {
                if pages[$0.surface] == "diff" { return "changes" }
                switch $0.kind { case .pty: return "terminal"; case .browser: return "browser"; default: return "chat" }
            }
        }

        init() {
            for (id, kind) in [("splitRight", TabKind.pty), ("splitBrowserRight", .browser)] {
                registry.register(Action(id: ActionID(rawValue: id), title: id, invoke: { [unowned self] invocation in
                    invocations[id] = invocation
                    split(invocation.target?.id, kind: kind)
                }, handler: {}))
            }
            // The diff viewer's page tab, placed right of the tab it names (AgentBesidePlacement).
            registry.register(Action(id: "openDiffViewer", title: "openDiffViewer", invoke: { [unowned self] invocation in
                invocations["openDiffViewer"] = invocation
                if let surface = split(invocation.target?.id, kind: .conversation) { pages[surface] = "diff" }
                publish()
            }, handler: {}))
            // A preview's browser tab, placed right of the tab it names (AgentBesidePlacement).
            registry.register(Action(id: "openBrowser", title: "openBrowser", invoke: { [unowned self] invocation in
                invocations["openBrowser"] = invocation
                split(invocation.target?.id, kind: .browser)
            }, handler: {}))
            registry.register(Action(id: "closeTab", title: "closeTab", invoke: { [unowned self] invocation in
                panes.removeAll { Self.id($0.surface) == invocation.target?.id }
                publish()
            }, handler: {}))
            publish()
        }

        /// Split Right on the targeted tab's pane: the new pane lands just right of it.
        @discardableResult
        private func split(_ tab: String?, kind: TabKind) -> SurfaceID? {
            guard let index = panes.firstIndex(where: { Self.id($0.surface) == tab }) else { return nil }
            let surface = SurfaceID(rawValue: next)
            panes.insert((PaneID(rawValue: next), surface, kind), at: index + 1)
            next += 1
            publish()
            return surface
        }

        private func publish() {
            let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].pane)) { left, pane in
                .split(id: nil, direction: .right, ratio: 0.5, a: left, b: .leaf(pane.pane))
            }
            let snapshots = panes.map { pane in
                var tab = TabSnapshot(surface: pane.surface, kind: pane.kind, cwd: pane.surface == 1 ? cwd : nil)
                if let page = pages[pane.surface] { tab.conversation = ConversationTabRef(page: page) }
                return PaneSnapshot(id: pane.pane, tabs: [tab])
            }
            let screen = ScreenSnapshot(id: 1, layout: layout, panes: snapshots)
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        }

        func click(_ id: String, toggles: AgentChatSplitToggles, url: String? = nil) {
            let actions = AgentChatTabActions(tab: { [chat] in chat }, registry: { [registry] in registry })
            toggles.toggle(id, cwd: id == "splitRight" ? nil : cwd, url: url, chat: chat, store: store, actions: actions)
        }

        /// The tab at `from` (left to right) dragged to `to`, as the user moves a pane.
        func move(_ from: Int, to: Int) {
            panes.insert(panes.remove(at: from), at: to)
            publish()
        }
    }

    @Test func terminalThenBrowserOpenRightOfTheChatInThatOrder() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "browser"])
    }

    /// Terminal asks for a terminal: a person's Split Right from a chat opens the New Tab page
    /// (cx-jfo7), which the header's Terminal must not (cx-00n1).
    @Test func terminalAsksForATerminal() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        #expect(row.invocations["splitRight"]?.opensTerminal == true)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.invocations["splitBrowserRight"]?.opensTerminal == false)
    }

    @Test func eachButtonClosesItsOwnPaneAndReopensAtTheEnd() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitBrowserRight", toggles: toggles)
        row.click("splitRight", toggles: toggles)
        #expect(row.order == ["chat", "browser", "terminal"])
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal"])
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "browser"])
    }
}
