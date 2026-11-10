import AppKit
import CmuxNextAgentPane
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

    /// A window with a terminal on the left and, on its right, a terminal (and, with `lower`, a diff below it).
    private struct Shown {
        let services: AppServices
        let window: NSWindow
        let left: PaneController
        let upper: PaneController
        let lower: PaneController?

        init(lower: Bool) throws {
            _ = NSApplication.shared
            let services = AppServices(environment: AppEnvironment.current([:]))
            let right: LayoutNode = lower
                ? .split(id: nil, resourceID: nil, direction: .down, ratio: 0.5, a: .leaf(2), b: .leaf(3)) : .leaf(2)
            let columns = [ColumnSnapshot(id: 10, width: 0.5, layout: .leaf(1)), ColumnSnapshot(id: 11, width: 0.5, layout: right)]
            var panes = [PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1, title: "Shell")]),
                         PaneSnapshot(id: 2, tabs: [TabSnapshot(surface: 2, title: "Server")])]
            if lower { panes.append(PaneSnapshot(id: 3, tabs: [TabSnapshot(surface: 3, title: "Logs")])) }
            let screen = ScreenSnapshot(id: 1, layout: .leaf(1), columns: columns, panes: panes)
            services.daemon.store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "Links", screens: [screen])]))
            let workspace = try #require(services.daemon.store.workspaces.first)
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
            left = try #require(content.panes.values.first { $0.pane.handle == 1 })
            upper = try #require(content.panes.values.first { $0.pane.handle == 2 })
            self.lower = content.panes.values.first { $0.pane.handle == 3 }
            services.linkOpener.placement = { .splitRight }
        }

        /// Opens a browser link from the left terminal through the link opener; answers the pane the tab was made
        /// in and whether the open then moved it into a new split.
        func openLink() -> (pane: LayoutPaneID?, split: Bool) {
            var made: LayoutPaneID?
            var split = false
            _ = services.linkOpener.open(from: left, kind: .browser) { pane, placed in
                made = pane.layoutPaneID
                split = placed != nil
                return false
            }
            return (made, split)
        }

        func close() { window.closeAfterTest() }
    }

    /// One terminal on the right: the link is a tab in it, never a split below it.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func aLinkBesideATerminalOpensAsATabInThePaneOnTheRight() throws {
        let shown = try Shown(lower: false)
        defer { shown.close() }
        #expect(shown.services.linkOpener.target(from: shown.left, kind: .browser) == .pane(shown.upper.layoutPaneID),
                "a browser link split a new pane below the terminal already on the right")
        let opened = shown.openLink()
        #expect(opened.pane == shown.upper.layoutPaneID)
        #expect(!opened.split, "the link moved into a new pane instead of staying a tab in the existing one")
        #expect(!shown.services.linkOpener.turns.isBusy(beside: shown.left.layoutPaneID))
    }

    /// Two panes on the right: still a tab in one of them, no third pane.
    @Test(.enabled("needs a display for pane geometry") { await Self.hasDisplay() })
    func aLinkBesideAFullColumnOpensAsATabThere() throws {
        let shown = try Shown(lower: true)
        defer { shown.close() }
        let lower = try #require(shown.lower)
        let opened = shown.openLink()
        #expect(opened.pane == lower.layoutPaneID)
        #expect(!opened.split)
    }
}
