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

        static func id(_ surface: SurfaceID) -> String { "surface:\(surface.rawValue)" }
        var chat: String { Self.id(1) }
        /// The row's tabs left to right, by kind.
        var order: [String] {
            panes.map { switch $0.kind { case .pty: "terminal"; case .browser: "browser"; default: "chat" } }
        }

        init() {
            for (id, kind) in [("splitRight", TabKind.pty), ("splitBrowserRight", .browser)] {
                registry.register(Action(id: ActionID(rawValue: id), title: id, invoke: { [unowned self] invocation in
                    split(invocation.target?.id, kind: kind)
                }, handler: {}))
            }
            registry.register(Action(id: "closeTab", title: "closeTab", invoke: { [unowned self] invocation in
                panes.removeAll { Self.id($0.surface) == invocation.target?.id }
                publish()
            }, handler: {}))
            publish()
        }

        /// Split Right on the targeted tab's pane: the new pane lands just right of it.
        private func split(_ tab: String?, kind: TabKind) {
            guard let index = panes.firstIndex(where: { Self.id($0.surface) == tab }) else { return }
            panes.insert((PaneID(rawValue: next), SurfaceID(rawValue: next), kind), at: index + 1)
            next += 1
            publish()
        }

        private func publish() {
            let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].pane)) { left, pane in
                .split(id: nil, direction: .right, ratio: 0.5, a: left, b: .leaf(pane.pane))
            }
            let snapshots = panes.map { PaneSnapshot(id: $0.pane, tabs: [TabSnapshot(surface: $0.surface, kind: $0.kind)]) }
            let screen = ScreenSnapshot(id: 1, layout: layout, panes: snapshots)
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        }

        func click(_ id: String, toggles: AgentChatSplitToggles) {
            let actions = AgentChatTabActions(tab: { [chat] in chat }, registry: { [registry] in registry })
            toggles.toggle(id, cwd: nil, chat: chat, store: store, actions: actions)
        }
    }

    @Test func terminalThenBrowserOpenRightOfTheChatInThatOrder() {
        let row = Row(), toggles = AgentChatSplitToggles()
        row.click("splitRight", toggles: toggles)
        row.click("splitBrowserRight", toggles: toggles)
        #expect(row.order == ["chat", "terminal", "browser"])
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
