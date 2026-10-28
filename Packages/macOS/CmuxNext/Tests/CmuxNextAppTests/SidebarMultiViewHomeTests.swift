import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextHomeEngine
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Multi-view with Home shown (Leo 2026-10-21, sr2-01a1608f-66bb: "you can just drag that workspace into a pane"). Home is
/// a pinned chat dock alone (`pinned-dock-alone-v1`), which takes no tab drop, and its screen has the layout's edge
/// dock bands. A sidebar row dropped on Home's right edge must show that workspace beside Home, and one dropped on
/// Home's bottom edge (in the pane's split zone or in the edge dock band) must stack it under Home, not merge its tabs
/// into a Home dock. Home must be laid out again in its half, not cut off. The #23651 dogfood found the right edge did
/// nothing and the bottom edge cut Home off at the midline.
@MainActor @Suite(.serialized, .enabled(if: !NSScreen.screens.isEmpty, "the drag tests need a display"))
struct SidebarMultiViewHomeTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    /// `home` (Home: its page tab in a pinned left chat dock, alone), `k1` and `k2` (a terminal and a browser tab each).
    static func tree() -> DaemonTree {
        var tree = Fixture.tree(["home", "k1", "k2"])
        var page = TabSnapshot(surface: 901, kind: .conversation, title: "Home")
        page.conversation = ConversationTabRef(page: HomeDock.page)
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
        tree.workspaces[0].screens = [ScreenSnapshot(id: 901, layout: .leaf(901), columns: [ColumnSnapshot(id: 901, width: 0.5, layout: .leaf(901), dock: dock)],
                                                     panes: [PaneSnapshot(id: 901, tabs: [page])])]
        tree.workspaces[0].kind = "home"
        return tree
    }

    /// The daemon's edge docks (`edge-docks-v1`): the layout has its edge dock bands, as in the app, where a drop
    /// near Home's bottom edge is offered a new bottom dock of Home.
    static let capabilities = [DaemonCapability.edgeDocks.rawValue]

    /// Drags `k1`'s row to `edge` of Home (`inset` of the layout, or `points`, in from it), checks what the hover
    /// resolves to, and releases it there.
    static func drop(_ f: Fixture, on edge: TabDropEdge, inset: CGFloat = 0.15, points: CGFloat? = nil) throws {
        try f.dragRow("k1", to: edge, inset: inset, points: points, release: false)
        let hover = f.services.dragSession.drag?.workspaceOutcome
        #expect(hover == .window(id: f.state.id, target: .beside(edge)),
                "k1 over Home's \(edge) edge (\(points.map { "\($0) pt" } ?? "\(inset)") in) resolves to \(String(describing: hover)): \(f.geometry)")
        f.services.dragSession.finish(commit: true)
        f.services.dragSession.finishLanding()
        f.frame()
    }

    /// Home's panes lie inside Home's half and fill its height: Home was laid out again, not cut off.
    static func expectHomeFits(_ f: Fixture, _ location: SourceLocation = #_sourceLocation) throws {
        let home = try #require(f.visible.first { $0.workspace.id == "home" }, sourceLocation: location)
        let frame = try #require(f.windowFrame("home"), sourceLocation: location)
        let panes = home.panes.values.map { $0.view.convert($0.view.bounds, to: nil) }
        try #require(!panes.isEmpty, "Home shows no pane", sourceLocation: location)
        for pane in panes {
            #expect(frame.insetBy(dx: -1, dy: -1).contains(pane), "a Home pane \(pane) reaches out of Home's half \(frame)", sourceLocation: location)
        }
        let tallest = panes.map(\.height).max() ?? 0
        #expect(tallest >= frame.height * 0.8, "Home's panes (\(panes)) do not fill its half \(frame)", sourceLocation: location)
    }

    @Test func aRowDroppedOnHomesRightEdgeShowsItsWorkspaceBesideHome() async throws {
        try await SidebarMultiViewWindowTests.withMultiView {
            let f = try await Fixture(keys: ["home", "k1", "k2"], tree: Self.tree(), capabilities: Self.capabilities)
            defer { f.close() }
            try #require(f.shown == ["home"], "the window shows \(f.shown)")
            let k1Tabs = f.tabs("k1")

            try Self.drop(f, on: .right)
            #expect(f.shown == ["home", "k1"], "the right-edge drop on Home did not show k1 beside it: \(f.shown) \(f.geometry)")
            #expect(f.onScreen == ["home", "k1"], "the sidebar lights \(f.onScreen)")
            #expect(f.state.workspaceID == "home", "the drop switched the focused workspace")
            #expect(f.tabs("k1") == k1Tabs, "the drop moved k1's tabs: it merged into Home instead of placing beside")
            let left = try #require(f.windowFrame("home")), right = try #require(f.windowFrame("k1"))
            #expect(right.minX >= left.maxX, "k1 is not on Home's right: \(left) \(right)")
            try Self.expectHomeFits(f)
        }
    }

    /// The bottom edge, in the pane's split zone (15% in, `nil`) and in the screen's bottom dock band (8 pt in: the
    /// band is `LayoutStyle.dockDropBand`, 24 pt, where the layout offers a new bottom dock of Home).
    @Test(arguments: [nil, 8.0] as [Double?])
    func aRowDroppedOnHomesBottomEdgeStacksItUnderHome(points: Double?) async throws {
        try await SidebarMultiViewWindowTests.withMultiView {
            let f = try await Fixture(keys: ["home", "k1", "k2"], tree: Self.tree(), capabilities: Self.capabilities)
            defer { f.close() }
            try #require(f.shown == ["home"], "the window shows \(f.shown)")
            try #require(f.controller.content?.layoutModel.acceptsEdgeDockDrops == true, "the layout has no edge dock bands")
            let k1Tabs = f.tabs("k1")

            try Self.drop(f, on: .bottom, points: points.map { CGFloat($0) })
            #expect(f.shown == ["home", "k1"], "the bottom-edge drop on Home did not stack k1 under it: \(f.shown) \(f.geometry)")
            #expect(f.tabs("k1") == k1Tabs, "the drop moved k1's tabs: it merged into Home instead of placing beside")
            #expect(f.services.workspace(id: "k1") != nil, "k1 closed: its tabs merged into Home")
            #expect(f.state.workspaceID == "home")
            let top = try #require(f.windowFrame("home")), bottom = try #require(f.windowFrame("k1"))
            #expect(bottom.maxY <= top.minY, "k1 is not under Home: \(top) \(bottom)") // window coordinates, y up
            try Self.expectHomeFits(f)
        }
    }
}
