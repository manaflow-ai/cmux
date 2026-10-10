import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextDaemon
import Testing

/// The chat header's [+] New tab, which becomes Hide tabs in the same spot (cx-qom0, ChatGPT's right
/// column): on a chat alone it opens a New Tab page on its right; with panes beside the chat it hides
/// them, closing nothing; a click on the hidden chat shows them again. Runs the header's path
/// against a store whose layout the actions change as the daemon would.
@MainActor
struct HeaderSideTabsTests {
    final class Screen {
        let store = DaemonStore()
        let registry = ActionRegistry()
        private(set) var panes: [(pane: PaneID, surface: SurfaceID, kind: TabKind)] = [(1, 1, .conversation)]
        private(set) var zoomed: PaneID?
        private var next: UInt64 = 2
        let chat = "surface:1"

        /// What shows: every pane, or only the zoomed one.
        var shown: [String] {
            panes.filter { zoomed == nil || $0.pane == zoomed }.map { $0.pane == 1 ? "chat" : "\($0.kind)" }
        }

        init() {
            registry.register(Action(id: "toggleSplitZoom", title: "toggleSplitZoom", invoke: { [unowned self] invocation in
                guard invocation.target?.id == chat else { return }
                zoomed = zoomed == nil ? 1 : nil
                publish()
            }, handler: {}))
            publish()
        }

        /// The New Tab page column the header asks for: a page in a new pane right of the chat.
        func openColumn() {
            panes.append((PaneID(rawValue: next), SurfaceID(rawValue: next), .conversation))
            next += 1
            publish()
        }

        func addTerminal() {
            panes.append((PaneID(rawValue: next), SurfaceID(rawValue: next), .pty))
            next += 1
            publish()
        }

        private func publish() {
            let layout = panes.dropFirst().reduce(LayoutNode.leaf(panes[0].pane)) { left, pane in
                .split(id: nil, direction: .right, ratio: 0.5, a: left, b: .leaf(pane.pane))
            }
            let snapshots = panes.map { PaneSnapshot(id: $0.pane, tabs: [TabSnapshot(surface: $0.surface, kind: $0.kind)]) }
            let screen = ScreenSnapshot(id: 1, zoomedPane: zoomed, layout: layout, panes: snapshots)
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        }

        /// One click on [+]; what the button reads after it.
        func click(_ toggles: AgentChatSplitToggles) -> String? {
            let actions = AgentChatTabActions(tab: { [chat] in chat }, registry: { [registry] in registry })
            return toggles.sideTabs(chat: chat, store: store, actions: actions, openColumn: openColumn)
                .map { $0 ? "Hide tabs" : "New tab" }
        }
    }

    @Test func newTabOpensThePageThenTheSameButtonHidesAndShowsIt() {
        let screen = Screen(), toggles = AgentChatSplitToggles()
        #expect(screen.click(toggles) == "Hide tabs")
        #expect(screen.shown == ["chat", "conversation"])
        #expect(screen.click(toggles) == "New tab")
        #expect(screen.shown == ["chat"])
        #expect(screen.click(toggles) == "Hide tabs")
        #expect(screen.shown == ["chat", "conversation"])
        // Hiding never closed the page: still one, not a second.
        #expect(screen.panes.count == 2)
    }

    @Test func panesBesideTheChatHideWithoutANewPage() {
        let screen = Screen(), toggles = AgentChatSplitToggles()
        screen.addTerminal()
        #expect(screen.click(toggles) == "New tab")
        #expect(screen.shown == ["chat"])
        #expect(screen.panes.count == 2)
    }
}
