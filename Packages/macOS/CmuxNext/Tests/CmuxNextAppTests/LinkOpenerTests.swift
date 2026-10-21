import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// ``LinkOpener``, the one path every link and path open takes, against a real pane. A link or
/// pick from a page (an agent chat, Home, the New Tab page, a Markdown or code page) opens as a
/// tab of its pane, never a split nobody asked for (Leo 2026-10-20). A terminal's or a browser
/// page's Cmd-click goes where `layout.linkPlacement` says: by default the item is made off-screen
/// in the source pane and handed to the move into a split on its right (Lawrence 2026-10-20).
@MainActor struct LinkOpenerTests {
    private static func tree() -> DaemonTree {
        let pane = PaneSnapshot(id: PaneID(rawValue: 1), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 1), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: .leaf(PaneID(rawValue: 1)), panes: [pane])
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// A pane with one terminal, alone on its screen (nothing on its right).
    private static func pane() throws -> (AppServices, PaneController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: tree())
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane)
    }

    @Test func aCmdClickIsMadeForTheMoveToTheRightNotShownInTheSource() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        var made: (PaneController, Bool)?
        let opened = services.linkOpener.open(from: pane, cmdClick: true) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(opened)
        #expect(made?.0 === pane)
        #expect(made?.1 == true, "the link opened as a tab over the source instead of moving right")
    }

    /// Leo 2026-10-20: a pull request's link in a chat opened in a split; nothing asked for one.
    @Test(arguments: [LinkPlacement.splitRight, .newColumn, .samePane])
    func aLinkFromAPageOpensAsATabInItsPane(_ placement: LinkPlacement) throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { placement }
        var made: (PaneController, Bool)?
        services.linkOpener.open(from: pane) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(made?.0 === pane)
        #expect(made?.1 == false, "a link from a page went to a split or column")
    }

    /// A refusal (a file that is gone, a pane that holds no browser) reports false, so the caller
    /// shows it instead of claiming the link opened.
    @Test func aRefusalIsReported() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        #expect(!services.linkOpener.open(from: pane) { _, _ in false })
    }
}
