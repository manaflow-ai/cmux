import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// ``LinkOpener``, the one path every link and path open takes, against a real pane: by default
/// the item is made off-screen in the source pane and handed to the move into a split on its right
/// (the source keeps showing what it showed); Same Pane opens it as a tab of the source.
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

    @Test func byDefaultTheItemIsMadeForTheMoveToTheRightNotShownInTheSource() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        var made: (PaneController, Bool)?
        let opened = services.linkOpener.open(from: pane) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(opened)
        #expect(made?.0 === pane)
        #expect(made?.1 == true, "the link opened as a tab over the source instead of moving right")
    }

    @Test func samePaneOpensATabInTheSource() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { .samePane }
        var made: (PaneController, Bool)?
        services.linkOpener.open(from: pane) { target, placed in
            made = (target, placed != nil)
            return true
        }
        #expect(made?.0 === pane)
        #expect(made?.1 == false)
    }

    /// A refusal (a file that is gone, a pane that holds no browser) reports false, so the caller
    /// shows it instead of claiming the link opened.
    @Test func aRefusalIsReported() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        #expect(!services.linkOpener.open(from: pane) { _, _ in false })
    }
}
