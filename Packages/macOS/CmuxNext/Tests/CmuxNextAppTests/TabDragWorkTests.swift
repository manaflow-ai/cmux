import AppKit
import CmuxNextBridge
@testable import CmuxNextApp
@testable import CmuxNextDaemon
@testable import CmuxNextLayout
@testable import CmuxNextTabs
import Foundation
import Testing

/// A tab drag across panes does its work once per display frame, not once per pointer event (CLAUDE.md "One frame
/// per display refresh"): the real session, fed `leftMouseDragged` events through its event monitor's handler at four
/// events a frame (a 480 Hz pointer on a 120 Hz display) and ticked by its frame client's callback. Per frame it hit
/// tests and moves the ghost panel at most once, at the latest point; the window order and the source pane's resolver
/// context are read once per drag, not per event; an edge's split room and final layout are computed once per zone;
/// the strip's gap layout runs only when the gap moves; a still pointer costs nothing. The outcome after each frame is
/// the one a direct hit test at the same point gives. `k0` shows two panes side by side: the dragged tab's pane (two
/// tabs) and a pane with one tab, the target. Counts are printed as `TABDRAG-WORK` lines.
@MainActor @Suite(.serialized) struct TabDragWorkTests {
    static let eventsPerFrame = 4
    static let frames = 40
    static let dt = 1.0 / 120

    struct Counts: CustomStringConvertible {
        var events = 0, frames = 0
        var hitTests = 0, windowOrderReads = 0, contextBuilds = 0
        var ghostRenders = 0, panelMoves = 0
        var dropLookups = 0, geometryComputes = 0, frameMaps = 0
        var phantomLayouts = 0, phantomRelayouts = 0

        var description: String {
            "events=\(events) frames=\(frames) hit_tests=\(hitTests) window_order_reads=\(windowOrderReads) "
                + "context_builds=\(contextBuilds) ghost_renders=\(ghostRenders) panel_moves=\(panelMoves) "
                + "drop_lookups=\(dropLookups) geometry_computes=\(geometryComputes) frame_maps=\(frameMaps) "
                + "phantom_layouts=\(phantomLayouts) phantom_relayouts=\(phantomRelayouts)"
        }
    }

    /// `k0`: a pane with two terminals left of a pane with one.
    static func tree() -> DaemonTree {
        let first = PaneSnapshot(id: PaneID(rawValue: 11), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 21), title: "~"),
                                                                   TabSnapshot(surface: SurfaceID(rawValue: 22), title: "~")])
        let second = PaneSnapshot(id: PaneID(rawValue: 12), tabs: [TabSnapshot(surface: SurfaceID(rawValue: 23), title: "~")])
        let screen = ScreenSnapshot(id: ScreenID(rawValue: 11), layout: .split(id: nil, resourceID: nil, direction: .right, ratio: 0.5,
                                                                               a: .leaf(first.id), b: .leaf(second.id)), panes: [first, second])
        var tree = DaemonTree(registryID: "s-local", workspaces: [
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: 1), key: WorkspaceKey(rawValue: "k0"), name: "k0", screens: [screen]),
        ])
        tree.personal = PersonalState(workspaces: [PersonalWorkspace(sessionID: "s-local", workspaceKey: WorkspaceKey(rawValue: "k0"), index: 0)])
        return tree
    }

    @Test func aCrossPaneDragWorksOncePerDisplayFrameNotPerEvent() async throws {
        let f = try await SidebarMultiViewWindowTests.Fixture(keys: ["k0"], tree: Self.tree())
        defer { f.close() }
        let session = f.services.dragSession
        try f.beginTabDrag()
        let drag = try #require(session.drag)
        let window = try #require(f.controller.window)
        let source = try #require(drag.source.pane)
        let target = try #require(f.controller.content?.panes.values.first { $0 !== source }, "k0 has no second pane")
        let stripView = target.view.stripView
        let strip = stripView.convert(stripView.bounds, to: nil)
        let layout = session.adapters(for: f.controller, drag: drag).layout
        let start = NSPoint(x: strip.midX, y: strip.midY)
        try #require(session.window(at: window.convertPoint(toScreen: start)) === f.controller,
                     "no window under the drag: \(f.geometry)")

        /// A drag event at a screen point: no window, so the session reads its location as the screen's (a window
        /// a display-less host placed elsewhere converts nothing).
        func dragged(toScreen point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        func counts() -> Counts {
            Counts(hitTests: drag.work.hitTests, windowOrderReads: drag.work.windowOrderReads, contextBuilds: drag.work.contextBuilds,
                   ghostRenders: drag.ghost.renders, panelMoves: drag.ghost.panelMoves, dropLookups: layout.lookups.targets,
                   geometryComputes: layout.lookups.geometryComputes, frameMaps: layout.lookups.frameMaps,
                   phantomLayouts: stripView.phantomWork.layouts, phantomRelayouts: stripView.phantomWork.relayouts)
        }
        func delta(_ a: Counts, _ b: Counts, events: Int, frames: Int) -> Counts {
            Counts(events: events, frames: frames, hitTests: b.hitTests - a.hitTests, windowOrderReads: b.windowOrderReads - a.windowOrderReads,
                   contextBuilds: b.contextBuilds - a.contextBuilds, ghostRenders: b.ghostRenders - a.ghostRenders,
                   panelMoves: b.panelMoves - a.panelMoves, dropLookups: b.dropLookups - a.dropLookups,
                   geometryComputes: b.geometryComputes - a.geometryComputes, frameMaps: b.frameMaps - a.frameMaps,
                   phantomLayouts: b.phantomLayouts - a.phantomLayouts, phantomRelayouts: b.phantomRelayouts - a.phantomRelayouts)
        }
        /// Sends `frames` display frames of `eventsPerFrame` drag events each along `path` (0...1), then checks that
        /// the outcome the frames left is a direct hit test's at the same point.
        func sweep(_ name: String, eventsPerFrame: Int = Self.eventsPerFrame, frames: Int = Self.frames,
                   _ path: (CGFloat) -> NSPoint) throws -> Counts {
            let before = counts()
            var events = 0
            for frame in 0..<frames {
                for step in 0..<eventsPerFrame {
                    let t = CGFloat(frame * eventsPerFrame + step + 1) / CGFloat(frames * eventsPerFrame)
                    _ = session.handle(try dragged(toScreen: window.convertPoint(toScreen: path(t))))
                    events += 1
                }
                _ = session.tick(drag, elapsed: Self.dt)
            }
            let measured = delta(before, counts(), events: events, frames: frames)
            print("TABDRAG-WORK \(name) \(measured)")
            let coalesced = drag.outcome
            session.update(drag.point)
            #expect(drag.outcome == coalesced, "\(name): the frames left \(coalesced), a direct hit test gives \(drag.outcome)")
            return measured
        }

        // Over the target pane: its middle, then down into its bottom edge's split zone, as the layout lays it out
        // (a display-less host clamps the window, so the pane view's frame is not the layout's).
        let layoutView = try #require(f.controller.content?.layoutView)
        let screen = try #require(layoutView.model.activeScreenID.flatMap { layoutView.screenViews[$0] })
        let cell = try #require(screen.geometry.panes[target.layoutPaneID], "the layout has no frame for the target pane")
        // Which point splits is the drop zones' call, not the test's: find the first one down the pane's middle that a
        // direct hit test resolves to a split, then sweep the pointer from the middle to it.
        func point(_ y: CGFloat) -> NSPoint { screen.convert(CGPoint(x: cell.midX, y: y), to: nil) }
        var seen: [String] = []
        var edgeY: CGFloat?
        for step in 1...40 {
            let y = cell.midY + CGFloat(step) / 40 * (cell.maxY - 1 - cell.midY)
            session.update(window.convertPoint(toScreen: point(y)))
            if case .newSplit = drag.outcome { edgeY = y; break }
            if step % 8 == 0 { seen.append("y=\(Int(y)): \(drag.outcome)") }
        }
        // A display-less host can place the window where no point of the pane reaches an edge band: then the sweep
        // stays in the pane's middle and the split zone's lookups go unmeasured (said in the TABDRAG-WORK line).
        if edgeY == nil { print("TABDRAG-WORK panes-edge unmeasured: no point down the target pane splits it: \(seen) cell=\(cell)") }
        let edge = edgeY ?? cell.midY + 0.4 * (cell.maxY - cell.midY)
        session.update(window.convertPoint(toScreen: point(cell.midY)))
        let panes = try sweep("panes") { t in point(cell.midY + t * (edge - cell.midY)) }
        if edgeY != nil, case .newSplit = drag.outcome {} else if edgeY != nil {
            Issue.record("the edge point resolves to \(drag.outcome) after the sweep")
        }
        // Along the target pane's strip: its gap follows.
        let gap = try sweep("strip") { t in NSPoint(x: strip.minX + 8 + t * (strip.width * 0.8), y: strip.midY) }
        guard case let .strip(stripID, _, _) = drag.outcome, stripID == target.stripModel.stripID else {
            Issue.record("the strip resolves to \(drag.outcome)")
            return
        }
        // The ghost settles, then a resting pointer costs nothing.
        _ = try sweep("settle", eventsPerFrame: 0, frames: 120) { _ in start }
        let still = try sweep("still", eventsPerFrame: 0, frames: 30) { _ in start }

        for (name, c) in [("panes", panes), ("strip", gap)] {
            #expect(c.hitTests <= c.frames, "\(name): more than one hit test per frame: \(c)")
            #expect(c.ghostRenders <= c.frames && c.panelMoves <= c.ghostRenders, "\(name): more than one ghost frame per frame: \(c)")
            #expect(c.windowOrderReads == 0, "\(name): the window order is read again with no window change: \(c)")
            #expect(c.contextBuilds == 0, "\(name): the resolver context is rebuilt with no tab change: \(c)")
        }
        // Two zones with a split (the bottom edge, and its room check's columns compute at most): once each.
        #expect(panes.geometryComputes <= 2, "panes: geometry computed per move: \(panes)")
        #expect(panes.dropLookups <= panes.frames, "panes: more than one drop lookup per frame: \(panes)")
        // One layout per gap position.
        #expect(gap.phantomLayouts <= 2 * (gap.phantomRelayouts + 1), "strip: the gap layout runs on moves that keep the gap: \(gap)")
        #expect(still.hitTests == 0 && still.ghostRenders == 0 && still.windowOrderReads == 0, "still: a resting pointer does work: \(still)")
    }
}
