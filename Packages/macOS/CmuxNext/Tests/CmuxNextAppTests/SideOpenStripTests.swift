import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextSettings
import Foundation
import Testing

/// Leo 2026-10-21: "the animation for opening up a new tab starts off in the left pane, and it doesn't
/// start off at the right". A link opened to the side is made unselected in the pane it was opened
/// from, then moved into a split on its right (``LinkOpener``). Its open must start where it lands: no
/// step of that round trip lists it in the left pane's strip, so the first strip that shows it, where
/// its tab opens, is the one on the right.
@MainActor @Suite(.serialized) struct SideOpenStripTests {
    private static let left = PaneID(rawValue: 1), right = PaneID(rawValue: 2)
    private static let home = SurfaceID(rawValue: 1), link = SurfaceID(rawValue: 2)

    /// One screen: the left pane with `surfaces`, and with `moved` a pane split off on its right holding those.
    private static func tree(left surfaces: [SurfaceID], right moved: [SurfaceID] = []) -> DaemonTree {
        func pane(_ id: PaneID, _ surfaces: [SurfaceID]) -> PaneSnapshot {
            PaneSnapshot(id: id, tabs: surfaces.map { TabSnapshot(surface: $0, title: "~") })
        }
        var panes = [pane(left, surfaces)], layout = LayoutNode.leaf(left)
        if !moved.isEmpty {
            panes.append(pane(right, moved))
            layout = .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5, a: .leaf(left), b: .leaf(right))
        }
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 1), layout: layout, panes: panes)
        return DaemonTree(workspaces: [WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: nil, name: "w1", screens: [screen])])
    }

    /// The left pane, with one terminal and nothing on its right.
    private static func pane() throws -> (AppServices, PaneController) {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.daemon.store.apply(snapshot: tree(left: [home]))
        let model = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"w1","workspace_key":"w1"}"#.utf8))
        let pane = PaneController(pane: model, daemon: services.daemon, layoutPaneID: LayoutPaneID(model.id), services: services,
                                  state: WindowState(record: record))
        return (services, pane)
    }

    /// The surfaces `pane`'s strip lists once it took the store's tabs.
    private static func listed(_ pane: PaneController) -> [SurfaceID] {
        pane.syncStripFromStore()
        return pane.stripModel.tabs.compactMap { item in pane.pane.tabs.first { $0.id == item.id.rawValue }?.surface }
    }

    @Test func aLinkOpenedToTheRightNeverShowsInTheLeftPanesStrip() throws {
        let (services, pane) = try Self.pane()
        defer { pane.teardown() }
        services.linkOpener.placement = { .splitRight }
        var placed: (@MainActor (SurfaceID) -> Void)?
        let opened = services.linkOpener.open(from: pane, cmdClick: true) { _, then in
            placed = then
            return true
        }
        #expect(opened)
        // The daemon's echo lists the new tab in the left pane before its answer names it.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home, Self.link]))
        #expect(Self.listed(pane) == [Self.home], "the new tab opened in the left pane's strip before its answer")
        let then = try #require(placed)
        then(Self.link)
        #expect(Self.listed(pane) == [Self.home], "the new tab opened in the left pane's strip on its way right")
        // The move lands: the tab is in the pane on the right, the first strip that lists it.
        services.daemon.store.apply(snapshot: Self.tree(left: [Self.home], right: [Self.link]))
        #expect(Self.listed(pane) == [Self.home])
        #expect(services.daemon.store.workspaces.first?.screens.first?.panes.first { $0.handle == Self.right }?.tabs.map(\.surface) == [Self.link])
    }
}
