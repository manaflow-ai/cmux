import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
import Foundation
import Testing

/// Debug Settings `sidebar.multiView` with the Home workspace on screen (dogfood 2026-10-21, showcase seed): Home
/// is one pinned chat dock that takes no tab, alone on its screen. A sidebar row dropped on an edge of it shows that
/// workspace beside Home, as on any pane edge; Home and the workspace stacked under it each lay out in their own
/// half. Closing one of three shown workspaces leaves the other two on screen. These run in the serialized
/// `SidebarMultiViewWindowTests`.
extension SidebarMultiViewWindowTests {
    /// The Home workspace as the daemon lists it: kind "home", a lone pinned agent chat dock (no tabs taken).
    static let homeKey = "home"

    static func homeTree(_ keys: [String]) -> DaemonTree {
        var tree = Fixture.tree(keys)
        guard let index = tree.workspaces.firstIndex(where: { $0.key?.rawValue == homeKey }) else { return tree }
        let dock = DockSnapshot(edge: .left, mode: .docked, role: .agentChat, isPinned: true)
        let pane = PaneSnapshot(id: PaneID(rawValue: 900), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 900), title: "Chief")])
        tree.workspaces[index].screens = [ScreenSnapshot(id: ScreenID(rawValue: 900), layout: .leaf(pane.id),
                                                         columns: [ColumnSnapshot(id: 900, width: 0.5, layout: .leaf(pane.id), dock: dock)],
                                                         panes: [pane])]
        tree.workspaces[index].kind = "home"
        return tree
    }

    /// The window shows Home (focused) and nothing beside it.
    static func homeFixture() async throws -> Fixture {
        let keys = [homeKey, "k1", "k2"]
        let f = try await Fixture(keys: keys)
        f.services.machines.local.store.apply(snapshot: homeTree(keys))
        try await Task.sleep(for: .milliseconds(100))
        f.controller.showWorkspace(requested: homeKey)
        f.frame()
        try #require(f.shown == [homeKey], "the window shows \(f.shown)")
        try #require(f.controller.content?.panes.values.first?.layoutPaneID.rawValue != nil, "Home has no pane")
        return f
    }

    /// A point 12% in from `edge` of Home's dock pane (screen coordinates), inside the pane's edge band and the
    /// layout's visible area.
    static func homeEdgePoint(_ f: Fixture, _ edge: TabDropEdge) throws -> CGPoint {
        let pane = try #require(f.controller.content?.panes.values.first)
        let layout = try #require(f.controller.content?.layoutView)
        let r = pane.view.convert(pane.view.bounds, to: nil).intersection(layout.convert(layout.bounds, to: nil))
        let (dx, dy) = (r.width * 0.12, r.height * 0.12)
        let point = switch edge {
        case .left: CGPoint(x: r.minX + dx, y: r.midY)
        case .right: CGPoint(x: r.maxX - dx, y: r.midY)
        case .top: CGPoint(x: r.midX, y: r.maxY - dy)
        case .bottom: CGPoint(x: r.midX, y: r.minY + dy)
        }
        return try #require(f.controller.window).convertPoint(toScreen: point)
    }

    @Test func aRowDroppedOnTheRightEdgeOfHomesDockShowsItBesideHome() async throws {
        try await Self.withMultiView {
            let f = try await Self.homeFixture()
            defer { f.close() }
            try f.dragRow("k1", toScreen: try Self.homeEdgePoint(f, .right), release: false)
            let outcome = f.services.dragSession.drag?.workspaceOutcome
            #expect(outcome == .window(id: f.state.id, target: .beside(.right)), "a row on Home's right edge resolves to \(String(describing: outcome))")
            f.services.dragSession.finish(commit: true)
            f.services.dragSession.finishLanding()
            f.frame()
            #expect(f.shown == [Self.homeKey, "k1"], "the drop on Home's right edge shows \(f.shown) \(f.geometry)")
            #expect(f.state.viewSet == .split(stacked: false, first: .workspace(Self.homeKey), second: .workspace("k1")))
            #expect(f.state.workspaceID == Self.homeKey)
        }
    }

    /// Home stacked over `k1`: each workspace's layout and panes fit its own half, at its height (Home's chat was
    /// cut off at the midline, laid out at the full height). The set is placed directly, so this does not depend on
    /// the drop resolving on Home's edge.
    @Test func homeAndTheWorkspaceStackedUnderItEachLayOutInTheirOwnHalf() async throws {
        try await Self.withMultiView {
            let f = try await Self.homeFixture()
            defer { f.close() }
            f.controller.placeBeside("k1", edge: .bottom, at: try Self.homeEdgePoint(f, .bottom))
            f.frame()
            try #require(f.shown == [Self.homeKey, "k1"], "Home and k1 are not both shown: \(f.shown) \(f.geometry)")
            #expect(f.state.viewSet == .split(stacked: true, first: .workspace(Self.homeKey), second: .workspace("k1")))
            for content in f.visible {
                let slot = content.contentView.convert(content.contentView.bounds, to: nil)
                let layout = content.layoutView.convert(content.layoutView.bounds, to: nil)
                #expect(abs(layout.height - slot.height) <= 1, "\(content.workspace.id)'s layout is \(layout.height) tall in a \(slot.height) half")
                #expect(slot.insetBy(dx: -1, dy: -1).contains(layout), "\(content.workspace.id)'s layout \(layout) spills out of its half \(slot)")
                for pane in content.panes.values {
                    let frame = pane.view.convert(pane.view.bounds, to: nil)
                    #expect(slot.insetBy(dx: -1, dy: -1).contains(frame),
                            "\(content.workspace.id)'s pane \(frame) is cut off by its half \(slot)")
                }
            }
        }
    }

    /// Leo 2026-10-21: closing one of three shown workspaces leaves the other two on screen, in their places.
    @Test func closingOneOfThreeShownWorkspacesLeavesTheOtherTwo() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .left)
            try f.dragRow("k2", to: .bottom)
            try #require(f.shown == ["k0", "k1", "k2"], "three are not shown: \(f.shown)")
            f.services.machines.local.store.apply(snapshot: Fixture.tree(["k0", "k1", "k3"]))
            try await Task.sleep(for: .milliseconds(100))
            f.controller.showWorkspace(requested: f.state.workspaceID)
            f.frame()
            #expect(f.shown == ["k0", "k1"], "closing k2 left \(f.shown) on screen")
            #expect(f.onScreen == ["k0", "k1"])
            #expect(f.state.viewSet == .split(stacked: false, first: .workspace("k1"), second: .workspace("k0")))
            #expect(f.state.workspaceID == "k0")
        }
    }
}
