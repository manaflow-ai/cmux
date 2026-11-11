import AppKit
import CmuxNextBridge
import CmuxNextLayout
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextTestSupport
import Foundation
import Testing

/// Aziz 2026-11-09: "when I open a browser link, it shouldn't open in a new pane if there already exists another
/// pane. Mimic classic cmux behavior in cmux next." Classic cmux (`openTerminalBrowserLink`,
/// `BrowserRightSidePaneResolver`) opens a link as a new tab in the pane already on the source's right; it only
/// splits when nothing is there. cmux-next split below a right pane that held no browser yet (a terminal, a diff),
/// so every first link beside a terminal made a new pane.
@MainActor @Suite(.serialized, .closesItsWindows) struct LinkReusesExistingPaneTests {
    static func hasDisplay() -> Bool { !NSScreen.screens.isEmpty }

    /// What the faked `new-frontend-browser-tab` was asked.
    @MainActor private final class Creates {
        var made: [(pane: CmuxNextDaemon.PaneID, url: String, activate: Bool, split: ConversationTabSplit?)] = []
    }

    /// An agent chat docked left and, on its right, one terminal (a dev server's), on a daemon that makes a link's tab
    /// in its split (`frontend-browser-tab-split-v1`); browser tab creates are faked (recorded, then refused). The
    /// same window as ChatDockToolPlacementTests, whose right column the default main pane layout measures.
    private struct Shown {
        let services: AppServices
        let window: NSWindow
        let chat: PaneController
        let right: PaneController
        let creates: Creates

        init() throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            let store = services.daemon.store
            let served: [DaemonCapability] = [.dockColumnRole, .frontendBrowserTabs, .frontendBrowserTabSplit, .splitClientKeys, .splitClientSplitID]
            let list = served.map { "\"\($0.rawValue)\"" }.joined(separator: ",")
            let json = #"{"app":"cmux-tui","protocol":1,"session":"link-reuse","generation":"g1","capabilities":["# + list + "]}"
            let identity = try JSONDecoder().decode(DaemonIdentity.self, from: Data(json.utf8))
            store.noteHandshake(identity)
            store.connectionState = .connected(identity)
            let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat)
            let columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1), dock: dock), ColumnSnapshot(id: 11, width: 1, layout: .leaf(2))]
            let panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Chat")]),
                         PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, title: "Server")])]
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
            store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Links", screens: [screen])]))
            let creates = Creates()
            self.creates = creates
            let browserTabs = services.cache.browserTabs
            browserTabs.serves = { _ in true }
            browserTabs.cefUnavailable = { nil }
            browserTabs.create = { _, pane, url, _, _, activate, _, split in
                creates.made.append((pane, url, activate, split))
                throw CancellationError()
            }
            let workspace = try #require(store.workspaces.first)
            let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"links-window","workspace_key":"Links"}"#.utf8))
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
            self.services = services
            self.window = window
            chat = try #require(content.panes.values.first { $0.pane.handle == 1 })
            right = try #require(content.panes.values.first { $0.pane.handle == 2 })
            services.linkOpener.placement = { .splitRight }
        }

        func close() { window.closeAfterTest() }
    }

    /// A link clicked in the chat (`openWeb`, as `AgentTabContent` and a terminal's Cmd-click open it) with a terminal
    /// on the right: a tab made, shown, in that terminal's pane; no new pane below it.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() }, .timeLimit(.minutes(1)))
    func aLinkBesideATerminalOpensAsATabInThePaneOnTheRight() async throws {
        let shown = try Shown()
        defer { shown.close() }
        let store = shown.services.daemon.store
        let url = try #require(URL(string: "https://example.com/"))

        #expect(shown.services.linkOpener.openWeb(url, from: shown.chat, background: false))

        #expect(!store.pendingIntents.contains { if case .splitPane = $0 { true } else { false } },
                "the link split a new pane below the terminal already on the right")
        #expect(store.workspaces.first?.screens.first?.panes.count == 2, "a new pane showed")
        for _ in 0..<20 where shown.creates.made.isEmpty { await Task.yield() }
        let made = try #require(shown.creates.made.first, "no browser tab was asked of the daemon")
        #expect(made.pane == shown.right.pane.handle, "the link's tab was not made in the pane on the right")
        #expect(made.split == nil, "the link's tab was made in a new split: \(String(describing: made.split))")
        #expect(made.activate, "the link's tab was made in the background, to be moved into a new pane")
    }

    /// A browser the person asks for that is not a link (a dock's Browser button, a New Tab page pick) keeps Leo's
    /// lower split beside a terminal (2026-10-31: split "when there's a terminal that gets opened when there's
    /// already a browser, and vice versa"); only links reuse the pane.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func aBrowserThatIsNoLinkStillSplitsBelowATerminal() throws {
        let shown = try Shown()
        defer { shown.close() }
        #expect(shown.services.linkOpener.target(from: shown.chat, kind: .browser) == .splitBelow(of: shown.right.layoutPaneID))
    }
}
