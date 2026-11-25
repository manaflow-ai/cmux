import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextDesign
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import QuartzCore
import Testing

/// Leo 2026-11-06, the motion targets: "every affected element moves together from its start to its end position,
/// monotonically, with no overshoot to a wrong position and no snap or pop-in after the animation ends." This suite
/// checks them (``MotionTargetTrace``) for a reorder of the sidebar's workspace rows: the model's order changes (a
/// move-up or move-down action, an agent's reorder, the daemon's echo of a drop) and the list reloads with motion.
///
/// A reorder has no manual frame clock: `RowMotion` sets every row's frame to its slot at once and adds an additive
/// `.move` spring from where it showed (`SidebarDragSpring.move`), which the render server draws. So each frame is
/// sampled from the row's layer at a fixed media time, the springs' begin time plus k/120 s (`MotionPath.value(at:)`,
/// Core Animation's own spring), not at real time, and the samples do not depend on how busy the runner is. A row's
/// shown y is its layer's top in the list's coordinates; the list does not scroll in these cases (checked), so every
/// sample has `containerStep: nil` (each row is itself what moves). After the last frame the move's end runs (`RowMotion.land`) and one more layout
/// pass, and each row's model y then is its rest.
///
/// The springs run only in a window on an awake screen (`SidebarDragSpring.move` and `Motion.canAnimate` land the
/// frames at once anywhere else), so these cases need a display worker (`--display`); without one they are skipped,
/// as `SidebarRowsMoveOnRenderServerTests` is.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct SidebarReorderMotionTargetTests {
    /// w5 moves to the top of twelve: w5 rises four rows, w1 to w4 go down one row each.
    @Test(.enabled("needs an awake display and animations on, or every reorder snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aRowMovedToTheTopMovesWithTheRowsItPasses() throws {
        let trace = try Self.trace(from: Array(1...12), to: [5, 1, 2, 3, 4] + Array(6...12))
        Self.report("sidebar reorder, w5 to the top", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    /// w2 moves down one row (a move-down action): w2 and w3 swap places on one spring.
    @Test(.enabled("needs an awake display and animations on, or every reorder snaps anyway") {
        await SidebarInsertWhileDisplayAsleepTests.animatesHere()
    })
    func aRowMovedDownOneRowSwapsWithItsNeighbour() throws {
        let trace = try Self.trace(from: Array(1...12), to: [1, 3, 2] + Array(4...12))
        Self.report("sidebar reorder, w2 down one", trace)
        #expect(trace.violations.isEmpty, "\(trace.violations.count) frames break a motion target: \(trace.violations.prefix(4))")
    }

    // MARK: - The rig

    /// The local machine's section with the workspaces `ids`, in that order (the daemon's rows).
    static func sections(_ ids: [Int]) -> [CmuxNextSidebar.SidebarSection] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: ids.map {
            WorkspaceSnapshot(id: WorkspaceHandle(rawValue: UInt64($0)), key: nil,
                              resourceID: ResourceID(rawValue: "ws-\($0)"), name: "w\($0)")
        }))
        return SidebarMapping.shared.sections(store.sidebarSections, machine: SidebarMachine(id: .local, name: "This Mac", kind: .local))
    }

    /// The workspaces `start` in a sidebar in a window on screen, with Reduce Motion off; the model's order becomes
    /// `end` and the list reloads with motion. Records every moved workspace row: its y before the change (frame 0),
    /// then at the springs' begin plus k/120 s to their end and one frame past it, then its rest after the move's end
    /// and one more layout pass.
    static func trace(from start: [Int], to end: [Int]) throws -> MotionTargetTrace {
        let first = Self.sections(start)
        let model = SidebarModel(sections: first, activeWorkspaceID: try #require(first.first?.workspaces.first?.id))
        let sidebar = SidebarView(model: model, design: DesignSettings())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 480)
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.closeAfterTest() }
        window.contentView?.addSubview(sidebar)
        window.orderFrontRegardless()
        try #require(window.screen != nil, "SETUP: the sidebar's window is on no screen")
        sidebar.layoutSubtreeIfNeeded()
        let list = sidebar.list
        list.reload(animated: false)
        // Synchronous from here to the reset: the override is process-wide.
        Motion.reduceMotionOverride = false
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.sidebar.animatesMovement, "SETUP: sidebar movement is off on this host")
        // A reorder the pointer is over waits for it to leave (`SidebarClickMovesNoRowTests`); no pointer here.
        list.pointerIsOverList = { _ in false }
        let clip = try #require(list.enclosingScrollView?.contentView)
        let scrolled = clip.bounds.minY

        let before = CACurrentMediaTime()
        let rows = Self.workspaceRows(list)
        let startY = Dictionary(rows.map { ($0.key, Self.shownY($0.view, at: before)) }, uniquingKeysWith: { first, _ in first })
        model.sections = Self.sections(end)
        list.reload(animated: true, fromModel: true)

        try #require(clip.bounds.minY == scrolled, "the list scrolled \(clip.bounds.minY - scrolled) pt: the rows' y is not where they show")
        #expect(list.rowViews.values.allSatisfy { $0.alphaValue == 1 }, "a row fades: the reorder is not the case under test")
        let moved = Self.workspaceRows(list).filter { row in
            startY[row.key].map { abs($0 - (row.view.layer?.frame.minY ?? $0)) > MotionTargetTrace.tolerance } ?? false
        }
        try #require(!moved.isEmpty, "the reorder moved no row")
        let layers = try moved.map { try #require($0.view.layer, "\($0.key) has no layer") }
        let begin = try #require(Self.springBegin(layers), "the reorder started no spring: the rows landed at once")
        let springEnd = layers.compactMap { layer in
            [MotionPath(layer, "position").end, MotionPath(layer, "bounds.size").end].compactMap { $0 }.max()
        }.max() ?? begin
        try #require(springEnd - begin > 3.0 / 120, "the reorder did not animate (\(springEnd - begin) s)")

        var trace = MotionTargetTrace()
        for row in moved {
            if let y = startY[row.key] { trace.record("\(row.key)", y, containerStep: nil) }
        }
        // At most 5 s of frames: a slower animation speed still ends inside it.
        let frames = min(600, Int(((springEnd - begin) * 120).rounded(.up)) + 1)
        for k in 0...frames {
            let time = begin + Double(k) / 120
            for row in moved { trace.record("\(row.key)", Self.shownY(row.view, at: time), containerStep: nil) }
        }
        // The move's end puts every row on its layout frame, then one more layout pass: each row's model y is its rest.
        RowMotion.land(list)
        list.needsLayout = true
        sidebar.layoutSubtreeIfNeeded()
        for row in moved { trace.settle("\(row.key)", row.view.layer?.frame.minY ?? .nan) }
        return trace
    }

    /// The shown workspace rows, by key.
    static func workspaceRows(_ list: SidebarListView) -> [(key: SidebarRowKey, view: SidebarRowView)] {
        list.rowViews.compactMap { key, view -> (key: SidebarRowKey, view: SidebarRowView)? in
            if case .workspace = key { (key, view) } else { nil }
        }
    }

    /// The top `view` shows at media time `time`, in the list's layer coordinates: its model geometry plus every spring
    /// on its layer, as the render server draws it.
    static func shownY(_ view: NSView, at time: CFTimeInterval) -> CGFloat {
        guard let layer = view.layer else { return view.frame.minY }
        let position = MotionPath(layer, "position").value(at: time)
        let size = MotionPath(layer, "bounds.size").value(at: time)
        return position.y - layer.anchorPoint.y * size.y
    }

    /// The media time the reorder's springs begin (`SidebarDragSpring.move` starts one batch at one time).
    static func springBegin(_ layers: [CALayer]) -> CFTimeInterval? {
        layers.flatMap { layer in
            (layer.animationKeys() ?? []).filter { $0.hasPrefix("\(SidebarDragSpring.batchKey).") }.compactMap { key in
                layer.animation(forKey: key).map { layer.convertTime($0.beginTime, to: nil) }
            }
        }.min()
    }

    static func report(_ name: String, _ trace: MotionTargetTrace) {
        print("motion-trace: \(name): \(trace.summary)")
    }
}
