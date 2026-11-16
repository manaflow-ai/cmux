import AppKit
import CmuxNextBridge
import CmuxNextLayout
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Lawrence, 2026-11-10: "I press the terminal button or the browser button and then there are multiple steps. It's very
/// slow and laggy." The chat header's Terminal with nothing on the chat's right made a terminal tab in the chat's own pane
/// (hidden), waited for the store to list it, and moved it to a new split: two daemon round trips before anything showed.
/// The header's Split Right is one `split` whose stand-in pane shows at the press, so the header runs that when the rule
/// below says the two give the same place (``LinkOpener/terminalSplitsAtOnce(from:)``).
@MainActor @Suite(.serialized, .closesItsWindows) struct HeaderTerminalSplitAtOnceTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    private struct Shown {
        let services: AppServices
        /// Kept alive: a pane's workspace is a weak reference, and without it every open reads as a split right.
        let content: WorkspaceContentController
        let state: WindowState
        let window: NSWindow
        let chat: PaneController

        /// A chat's pane alone on its screen, or with a terminal's pane on its right, on a daemon advertising `capabilities`.
        init(right: Bool, capabilities: [DaemonCapability]) throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            let identity = DaemonIdentity(capabilities: capabilities.map(\.rawValue), generation: DaemonGeneration(rawValue: "header-terminal"))
            services.daemon.store.noteHandshake(identity)
            services.daemon.store.connectionState = .connected(identity)
            var panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Chat")])]
            if right { panes.append(PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, kind: .browser, title: "Preview")])) }
            // With a right side: the chat is docked left and its strip column holds a browser (as ChatDockToolPlacementTests).
            let columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: DockSnapshot(edge: .left, mode: .docked, role: .agentChat)),
                           ColumnSnapshot(id: 11, width: 1, layout: .leaf(2))]
            let screen = right ? ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes) : ScreenSnapshot(id: 1, layout: .leaf(1), panes: panes)
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Chat", screens: [screen])]))
            let workspace = try #require(services.daemon.store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"header-terminal-window","workspace_key":"Chat"}"#.utf8))
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1600, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let state = WindowState(record: record)
            let content = WorkspaceContentController(workspace: workspace, daemon: services.daemon, services: services, state: state)
            content.contentView.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
            window.contentView = content.contentView
            window.orderFrontRegardless()
            content.applyCurrent()
            content.contentView.layoutSubtreeIfNeeded()
            self.services = services
            self.content = content
            self.state = state
            self.window = window
            chat = try #require(content.panes.values.first { $0.pane.handle == 1 })
        }

        func close() { window.closeAfterTest() }
        var target: String { String(describing: services.linkOpener.target(from: chat, besideChat: true, kind: .terminal)) }
    }

    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func withNothingOnTheChatsRightTheTerminalIsOneSplit() throws {
        let shown = try Shown(right: false, capabilities: [.splitClientKeys])
        defer { shown.close() }
        #expect(shown.chat.workspace === shown.content)
        #expect(shown.services.linkOpener.terminalSplitsAtOnce(from: shown.chat), "made in the chat's pane and moved; the rule's target: \(shown.target)")
    }

    /// The right column's own rule stays (a tab in the pane holding a terminal, a split below another kind): Split Right
    /// would add a third column there.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func withAPaneOnTheChatsRightTheRightColumnRuleStays() throws {
        let shown = try Shown(right: true, capabilities: [.splitClientKeys, .dockColumnRole])
        defer { shown.close() }
        #expect(shown.services.linkOpener.target(from: shown.chat, besideChat: true, kind: .terminal) != .splitRight(of: shown.chat.layoutPaneID))
        #expect(!shown.services.linkOpener.terminalSplitsAtOnce(from: shown.chat), "the rule's target: \(shown.target)")
    }

    /// A daemon that shows no split before its reply keeps the make-and-move, whose turn the next open waits for.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func anOlderDaemonKeepsTheMove() throws {
        let shown = try Shown(right: false, capabilities: [])
        defer { shown.close() }
        #expect(!shown.services.linkOpener.terminalSplitsAtOnce(from: shown.chat))
    }

    /// An open beside the chat still on its way decides the column: the terminal waits for it in the opener's turns.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func anOpenOnItsWayKeepsTheTurn() throws {
        let shown = try Shown(right: false, capabilities: [.splitClientKeys])
        defer { shown.close() }
        var finish: (@MainActor () -> Void)?
        shown.services.linkOpener.turns.serially(beside: shown.chat.layoutPaneID) { finish = $0 }
        #expect(!shown.services.linkOpener.terminalSplitsAtOnce(from: shown.chat))
        finish?()
        #expect(shown.services.linkOpener.terminalSplitsAtOnce(from: shown.chat))
    }
}
