import AppKit
import CmuxNextActions
import CmuxNextBridge
import CmuxNextLayout
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Terminal and browser commands share the dock's tool opener; its target is the right column,
/// including when the person most recently used its upper pane or links are set to Same Pane.
@MainActor @Suite(.serialized, .closesItsWindows) struct ChatDockToolPlacementTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    private struct Shown {
        let services: AppServices
        let content: WorkspaceContentController
        let state: WindowState
        let window: NSWindow
        let chat: PaneController
        let upper: PaneController
        let lower: PaneController?

        init(lower: Bool) throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            // The capability check reads the handshake's identity (StateResourceQueries.supports), which a
            // real connect records before its `.connected` event (DaemonStore.noteHandshake); the
            // connection state alone advertises nothing, and `openTool` then answers false.
            let identity = DaemonIdentity(capabilities: [DaemonCapability.dockColumnRole.rawValue],
                                          generation: DaemonGeneration(rawValue: "chat-tools"))
            services.daemon.store.noteHandshake(identity)
            services.daemon.store.connectionState = .connected(identity)
            let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
            let right: LayoutNode = lower
                ? .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(2), b: .leaf(3)) : .leaf(2)
            let columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: dock),
                           ColumnSnapshot(id: 11, width: 1, layout: right)]
            var panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Chat")]),
                         PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, kind: .browser, title: "Preview")])]
            if lower { panes.append(PaneSnapshot(id: 3, tabs: [TabSnapshot(surface: 3, title: "Terminal")])) }
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Tools", screens: [screen])]))
            let workspace = try #require(services.daemon.store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"tools-window","workspace_key":"Tools"}"#.utf8))
            let state = WindowState(record: record)
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1600, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            content.applyCurrent()
            content.contentView.layoutSubtreeIfNeeded()
            let chat = try #require(content.panes.values.first { $0.pane.handle == 1 })
            let upper = try #require(content.panes.values.first { $0.pane.handle == 2 })
            self.services = services
            self.state = state
            self.window = window
            self.content = content
            self.chat = chat
            self.upper = upper
            self.lower = content.panes.values.first { $0.pane.handle == 3 }
            services.linkOpener.placement = { .samePane }
        }

        func close() { window.closeAfterTest() }
    }

    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func oneRightPaneSplitsBelowForADockTool() throws {
        let shown = try Shown(lower: false)
        defer { shown.close() }
        var made: [LayoutPaneID] = []
        var moves = false
        #expect(ChatColumnPlacement.openTool(from: shown.chat, services: shown.services) { pane, placed in
            made.append(pane.layoutPaneID)
            moves = placed != nil
            return false
        })
        #expect(made == [shown.upper.layoutPaneID])
        #expect(moves, "a dock tool must split below the existing pane, not become a tab above")
        #expect(shown.services.linkOpener.target(from: shown.chat, besideChat: true) == .splitBelow(of: shown.upper.layoutPaneID))
        #expect(!shown.services.linkOpener.turns.isBusy(beside: shown.chat.layoutPaneID))
    }

    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func dockToolsReuseTheirKindAndSplitForTheOtherKind() throws {
        let shown = try Shown(lower: false)
        defer { shown.close() }
        #expect(shown.services.linkOpener.target(from: shown.chat, besideChat: true, kind: .browser) == .pane(shown.upper.layoutPaneID))
        #expect(shown.services.linkOpener.target(from: shown.chat, besideChat: true, kind: .terminal) == .splitBelow(of: shown.upper.layoutPaneID))
        var moves = true
        let opened = ChatColumnPlacement.openTool(from: shown.chat, services: shown.services, kind: .browser) { pane, placed in
            #expect(pane === shown.upper)
            moves = placed != nil
            return false
        }
        #expect(opened)
        #expect(!moves)
    }

    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func twoRightPanesAddATabInTheLowerPane() throws {
        let shown = try Shown(lower: true)
        defer { shown.close() }
        let lower = try #require(shown.lower)
        PaneHandlers.focus(shown.upper.layoutPaneID, in: shown.content)
        var made: [LayoutPaneID] = []
        var moves = true
        #expect(ChatColumnPlacement.openTool(from: shown.chat, services: shown.services) { pane, placed in
            made.append(pane.layoutPaneID)
            moves = placed != nil
            return false
        })
        #expect(made == [lower.layoutPaneID], "recent focus in the upper pane must not attract the new tool")
        #expect(!moves, "a third right-side split must never be made")
    }

    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func aDockToolWaitsForTheEarlierRightSideOpen() throws {
        let shown = try Shown(lower: false)
        defer { shown.close() }
        var finish: (@MainActor () -> Void)?
        shown.services.linkOpener.turns.serially(beside: shown.chat.layoutPaneID) { finish = $0 }
        var made = false
        #expect(ChatColumnPlacement.openTool(from: shown.chat, services: shown.services) { _, _ in made = true; return false })
        #expect(!made)
        finish?()
        #expect(made)
        #expect(!shown.services.linkOpener.turns.isBusy(beside: shown.chat.layoutPaneID))
    }
}
