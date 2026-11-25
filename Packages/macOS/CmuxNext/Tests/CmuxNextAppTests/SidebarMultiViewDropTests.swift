import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
import CmuxNextDesign
@testable import CmuxNextSidebar
@testable import CmuxNextTabs
import Foundation
import Testing

/// Debug Settings `sidebar.multiView`: a drop on the area of a workspace shown beside the focused one goes to that
/// workspace, not to the focused one. A sidebar row dropped on a pane edge there goes on that side of it; a row or a
/// tab over one of its panes or strips targets that pane; a tab released there focuses that workspace first, the
/// way a press does, unless Option files it away. The window shows `k1` (two panes) on the left of `k0` before each
/// test. These run in the serialized `SidebarMultiViewWindowTests`.
extension SidebarMultiViewWindowTests {
    /// A workspace drag keeps the focused row strong and every workspace already in the view lit while the
    /// existing pane drop overlay previews the split. This is deliberately frame-by-frame: a drag must not
    /// transiently navigate to the row being carried or clear the other visible rows.
    @Test func aRowDraggedToASplitEdgePreservesFocusAndVisibleRowHighlightsDuringThePreview() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k1", to: .left)
            try #require(f.shown == ["k0", "k1"])
            let k1 = try #require(f.visible.first { $0.workspace.id == "k1" })
            let pane = try #require(k1.panes.values.first)
            let paneFrame = pane.view.convert(pane.view.bounds, to: nil)
            let splitPoint = try #require(f.controller.window).convertPoint(toScreen: NSPoint(
                x: paneFrame.midX, y: paneFrame.minY + paneFrame.height * 0.15))

            let start = try f.rowPoint("k2")
            f.list.mouseDown(with: try f.event(.leftMouseDown, at: start))
            for dy in [CGFloat(-6), -12, -18] {
                f.list.mouseDragged(with: try f.event(.leftMouseDragged,
                                                        at: NSPoint(x: start.x, y: start.y + dy)))
                f.frame()
                #expect(f.state.workspaceID == "k0", "the held drag focused k2 at \(dy) pt")
                #expect(f.model.activeWorkspaceID?.rawValue == "k0")
                #expect(f.onScreen == ["k0", "k1"])
                #expect(f.litRows == ["k0", "k1"],
                        "visible rows lost their fills at \(dy) pt")
            }

            let content = try #require(f.controller.content).contentView
            let inside = content.convert(content.bounds, to: nil)
            f.list.mouseDragged(with: try f.event(.leftMouseDragged,
                                                   at: NSPoint(x: inside.midX, y: inside.midY)))
            #expect(f.services.dragSession.drag != nil)
            f.services.dragSession.update(splitPoint)
            f.frame()

            let drag = try #require(f.services.dragSession.drag)
            #expect(drag.workspaceOutcome == .window(id: f.state.id, target: .beside(.bottom)))
            #expect(f.state.workspaceID == "k0", "the split preview changed focus")
            #expect(f.onScreen == ["k0", "k1"])
            #expect(f.litRows == ["k0", "k1"])
            #expect(k1.layoutView.dropHighlightShowing, "the pane drop overlay did not show the split indicator")
            #expect(k1.layoutView.dropHighlightFrameInWindow != nil)

            f.services.dragSession.finish(commit: true)
            f.services.dragSession.finishLanding()
            f.frame()
            // The sidebar repaints the on-screen fills from its observation task (`SidebarView.observe`), a
            // MainActor turn after the drop changes `SidebarModel.onScreen`: give it bounded turns to run.
            for _ in 0..<120 where f.litRows != f.shown {
                try await Task.sleep(for: .milliseconds(10))
                f.frame()
            }
            #expect(f.state.workspaceID == "k0", "the split drop moved focus")
            #expect(f.onScreen == f.shown)
            #expect(f.shown.contains("k2"), "the dropped workspace did not join the current view")
            #expect(f.litRows == f.shown,
                    "the sidebar did not light every workspace in the view")
        }
    }

    /// The fixture with `k1` dropped on the left edge of `k0`.
    static func besideFixture() async throws -> Fixture {
        let f = try await Fixture()
        try f.dragRow("k1", to: .left)
        try #require(f.shown == ["k0", "k1"], "k1 is not beside k0: \(f.shown) \(f.geometry)")
        try #require(f.state.workspaceID == "k0")
        return f
    }

    /// `k3` (one pane, half the content area) beside `k0`; `k2` dropped on the bottom edge of `k3`'s pane goes under
    /// `k3`, not under `k0`. A pane half as wide has no room for a left or right split, so the bottom edge it is.
    @Test func aRowDroppedOnAPaneEdgeOfAWorkspaceBesideGoesBesideThatWorkspace() async throws {
        try await Self.withMultiView {
            let f = try await Fixture()
            defer { f.close() }
            try f.dragRow("k3", to: .left)
            try #require(f.shown == ["k0", "k3"], "k3 is not beside k0: \(f.shown) \(f.geometry)")
            let k3Tabs = f.tabs("k3")
            let (pane, _) = try f.paneCenter(of: "k3", index: 0)
            let frame = pane.view.convert(pane.view.bounds, to: nil)
            let point = try #require(f.controller.window).convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.minY + frame.height * 0.15))
            try f.dragRow("k2", toScreen: point, release: false)
            let outcome = f.services.dragSession.drag?.workspaceOutcome
            #expect(outcome == .window(id: f.state.id, target: .beside(.bottom)), "a row on k3's bottom pane edge resolves to \(String(describing: outcome))")
            f.services.dragSession.finish(commit: true)
            f.services.dragSession.finishLanding()
            f.frame()
            #expect(f.shown == ["k0", "k2", "k3"], "the drop on k3's edge did not show k2: \(f.shown) \(f.geometry)")
            #expect(f.state.workspaceID == "k0", "the drop moved the focus to \(f.state.workspaceID ?? "-")")
            #expect(f.tabs("k3") == k3Tabs, "the drop merged k2 into k3")
            #expect(f.state.viewSet == .split(stacked: false, first: .split(stacked: true, first: .workspace("k3"), second: .workspace("k2")),
                                              second: .workspace("k0")),
                    "k2 is not under k3: \(String(describing: f.state.viewSet))")
        }
    }

    @Test func aRowOverAPaneOfAWorkspaceBesidePreviewsAMergeIntoThatPane() async throws {
        try await Self.withMultiView {
            let f = try await Self.besideFixture()
            defer { f.close() }
            let (pane, point) = try f.paneCenter(of: "k1", index: 1)
            try f.dragRow("k2", toScreen: point, release: false)
            let drag = try #require(f.services.dragSession.drag)
            #expect(drag.workspaceOutcome == .window(id: f.state.id, target: .merge(.strip(stripID: pane.stripModel.stripID, index: pane.pane.tabs.count,
                                                                                         groupID: nil))),
                    "a row over k1's pane resolves to \(drag.workspaceOutcome)")
        }
    }

    /// The fake daemon never lands the move, so this checks where the drop resolves and that it focuses `k1`.
    @Test func aTabReleasedOnAPaneOfAWorkspaceBesideResolvesThereAndFocusesIt() async throws {
        try await Self.withMultiView {
            let f = try await Self.besideFixture()
            defer { f.close() }
            try f.beginTabDrag()
            let (pane, point) = try f.paneCenter(of: "k1", index: 1)
            f.services.dragSession.update(point)
            let drag = try #require(f.services.dragSession.drag)
            #expect(drag.outcome == .strip(stripID: pane.stripModel.stripID, index: pane.pane.tabs.count, groupID: nil),
                    "a tab over k1's pane resolves to \(drag.outcome)")
            f.services.dragSession.finish(commit: true)
            f.frame()
            #expect(f.state.workspaceID == "k1", "the tab dropped in k1 left the focus on \(f.state.workspaceID ?? "-")")
            #expect(f.shown == ["k0", "k1"])
        }
    }

    /// Option files the tab away: the focus stays on `k0`, and the drop still targets `k1`'s pane.
    @Test func anOptionDropOnAPaneOfAWorkspaceBesideLeavesTheFocus() async throws {
        try await Self.withMultiView {
            let f = try await Self.besideFixture()
            defer { f.close() }
            try f.beginTabDrag()
            let (pane, point) = try f.paneCenter(of: "k1", index: 1)
            f.services.dragSession.update(point)
            let drag = try #require(f.services.dragSession.drag)
            drag.filesAway = true
            #expect(drag.outcome == .strip(stripID: pane.stripModel.stripID, index: pane.pane.tabs.count, groupID: nil))
            #expect(f.services.dragSession.paneController(stripID: pane.stripModel.stripID) === pane, "the commit cannot find k1's pane")
            f.services.dragSession.finish(commit: true)
            f.frame()
            #expect(f.state.workspaceID == "k0", "the Option drop moved the focus to \(f.state.workspaceID ?? "-")")
        }
    }

    @Test func aTabReleasedOnAStripOfAWorkspaceBesideResolvesThereAndFocusesIt() async throws {
        try await Self.withMultiView {
            let f = try await Self.besideFixture()
            defer { f.close() }
            try f.beginTabDrag()
            let (pane, _) = try f.paneCenter(of: "k1", index: 1)
            let strip = pane.view.stripView
            let frame = strip.convert(strip.bounds, to: nil)
            let point = try #require(f.controller.window).convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.midY))
            f.services.dragSession.update(point)
            let drag = try #require(f.services.dragSession.drag)
            guard case let .strip(stripID, _, _) = drag.outcome else {
                Issue.record("a tab over k1's strip resolves to \(drag.outcome)")
                return
            }
            #expect(stripID == pane.stripModel.stripID, "the tab targets another strip than k1's")
            f.services.dragSession.finish(commit: true)
            f.frame()
            #expect(f.state.workspaceID == "k1", "the tab dropped on k1's strip left the focus on \(f.state.workspaceID ?? "-")")
        }
    }
}

extension SidebarMultiViewWindowTests.Fixture {
    /// The realized workspace rows that draw a fill in multi-view: the selection-colored ones
    /// (`SidebarPointerGestureTests.filledRows`) plus the soft fill of a row whose workspace is on screen beside
    /// the focused one (`WorkspaceRowView.isOnScreen`).
    var litRows: Set<String> {
        SidebarPointerGestureTests.filledRows(list).union(list.rowViews.compactMap { key, view -> String? in
            guard case let .workspace(id) = key, let row = view as? WorkspaceRowView, row.isOnScreen else { return nil }
            return id.rawValue
        })
    }

    /// The `index`th pane of `id`'s screen, and a point in the middle of its body on screen.
    func paneCenter(of id: String, index: Int) throws -> (PaneController, CGPoint) {
        let content = try #require(visible.first { $0.workspace.id == id }, "\(id) is not on screen")
        let order = content.layoutModel.screens.flatMap(\.layout.panes)
        try #require(order.count > index, "\(id) has \(order.count) panes")
        let pane = try #require(content.panes[order[index]])
        let frame = pane.view.convert(pane.view.bounds, to: nil)
        let point = try #require(controller.window).convertPoint(toScreen: NSPoint(x: frame.midX, y: frame.midY - frame.height * 0.1))
        return (pane, point)
    }

    /// A tab drag of the first tab of `k0`'s pane that has two, handed off by its strip.
    func beginTabDrag() throws {
        let source = try #require(controller.content?.panes.values.first { $0.pane.tabs.count > 1 }, "k0 has no pane with two tabs")
        let tab = try #require(source.pane.tabs.first)
        let strip = source.view.stripView
        let frame = try #require(strip.window).convertToScreen(strip.convert(strip.bounds, to: nil))
        let start = TabDragStart(tabID: CmuxNextTabs.TabID(tab.id), stripID: source.stripModel.stripID,
                                 screenFrame: CGRect(x: frame.minX, y: frame.minY, width: 120, height: frame.height),
                                 grabOffset: CGPoint(x: 20, y: 10), screenPoint: CGPoint(x: frame.minX + 20, y: frame.minY + 10), snapshot: nil)
        services.dragSession.begin(start, from: source)
        #expect(services.dragSession.drag != nil, "the tab drag did not start")
    }

    /// A hold-then-drag of `id`'s sidebar row to `point` (screen), released there unless `release` is false.
    func dragRow(_ id: String, toScreen point: CGPoint, release: Bool = true) throws {
        let start = try rowPoint(id)
        list.mouseDown(with: try event(.leftMouseDown, at: start))
        for dy in [CGFloat(-6), -12, -18] {
            list.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: start.x, y: start.y + dy)))
            frame()
        }
        let inside = controller.root.contentHost.convert(controller.root.contentHost.bounds, to: nil)
        list.mouseDragged(with: try event(.leftMouseDragged, at: NSPoint(x: inside.midX, y: inside.midY)))
        #expect(services.dragSession.drag != nil, "the window drag did not take the row over")
        services.dragSession.update(point)
        frame()
        guard release else { return }
        services.dragSession.finish(commit: true)
        services.dragSession.finishLanding()
        frame()
    }
}
