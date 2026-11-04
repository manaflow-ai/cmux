import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3d: during a close, a resize handle that stays shows in the middle of the gap between its panes,
/// in every frame (R-HARNESS's divider check on the films: the handle up to 15 device px off its gap, so a press on it
/// during a close could miss it by 7 pt). The closing pane keeps the gap on a side where the handle stays and covers it
/// where the handle goes (the one between it and the panes that take its place), so the gap a person sees is always the
/// kept handle's. Along the line through the handle's centre across its gap, the run that no shown pane host (live, or
/// closing with its ground) covers must hold the centre, centred within a point.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseKeptHandleTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// p1 | p2 | p3, made by splitting p1 of p1 | p3: closing p2 removes the divider between p1 and p2 (p1 grows over p2's
    /// place); the divider x, between p2 and p3, stays.
    @Test func theDividerOnTheClosingPanesTrailingSideStaysOnItsGap() throws {
        try Self.check(.split("x", axis: .horizontal, ratio: 2.0 / 3, a: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2")),
                              b: .leaf("p3")),
                       closing: "p2", kept: .split("x"))
    }

    /// p1 | p2 over p3, p1 a third wide: closing p2 grows p1 over its place; the divider v below p2 stays (its centre is over
    /// p2 until p1 passes it).
    @Test func theDividerBelowTheClosingPaneStaysOnItsGap() throws {
        try Self.check(.split("v", axis: .vertical, ratio: 0.5, a: .split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p1"), b: .leaf("p2")),
                              b: .leaf("p3")),
                       closing: "p2", kept: .split("v"))
    }

    /// Columns (p1 | p2) and p3: closing p2 grows p1 over its place; the edge of the first column stays.
    @Test func theColumnEdgeBesideAClosingSplitPaneStaysOnItsGap() throws {
        try Self.check(layout: .columns([LayoutColumn(id: "c0", width: 0.5, root: .split("x", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
                                         LayoutColumn(id: "c1", width: 0.5, root: .leaf("p3"))]),
                       focused: "p2", closing: "p2", kept: .columnEdge("c0"))
    }

    /// The last of three half-width columns closes while the strip shifts back: the edge of the column before it stays.
    @Test func theLastColumnsNeighbourEdgeStaysOnItsGapWhileTheStripShiftsBack() throws {
        try Self.check(layout: ColumnCloseScrollMotionTests.columns(3), focused: "p3", closing: "p3", kept: .columnEdge("c2"))
    }

    /// Guard (the films' px-close-pane-3): p0 | p1 | p2 split from p0 then p1, the middle one closes; the divider x on its
    /// leading side stays.
    @Test func theDividerOnTheClosingPanesLeadingSideStaysOnItsGap() throws {
        try Self.check(.split("x", axis: .horizontal, ratio: 1.0 / 3, a: .leaf("p0"), b: .split("y", axis: .horizontal, ratio: 0.5, a: .leaf("p1"), b: .leaf("p2"))),
                       closing: "p1", kept: .split("x"))
    }

    /// Guard (the films' px-close-column-c3): three columns, the middle one closes; the edge of the first stays.
    @Test func theEdgeBeforeAClosingMiddleColumnStaysOnItsGap() throws {
        try Self.check(layout: .columns([LayoutColumn(id: "c0", width: 1.0 / 3, root: .leaf("p0")), LayoutColumn(id: "c1", width: 1.0 / 3, root: .leaf("p1")),
                                         LayoutColumn(id: "c2", width: 1.0 / 3, root: .leaf("p2"))]),
                       focused: "p1", closing: "p1", kept: .columnEdge("c0"))
    }

    /// The `debug.motion` trace reports a closing pane's ground (`closing`, `[pane, x, y, width, height, alpha, z]`) apart
    /// from the live panes (`panes`, whose rows also say how their content is laid out): a trace judge that centres a
    /// handle on its panes' gap reads the closing ground beside it (R-HARNESS pair C), and the live-pane judges do not take
    /// it for a pane whose content is gone.
    @Test func theTraceReportsAClosingPaneApartFromTheLivePanes() throws {
        let rig = Rig(PaneGroundCoversPaneTests.column(PaneGroundCoversPaneTests.pair), focused: "p2")
        defer { rig.close() }
        let screen = try rig.screen
        _ = try #require(rig.model.showPaneClose("p2"), "p2 did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        let host = try #require(rig.root.context.closingHost("p2", of: "s"), "SETUP: p2 is not closing")
        try #require(!host.isHidden && host.showsClosingGround, "SETUP: p2's ground does not show")
        let sample = try #require(ScreenContentView.motionSample(screen), "the screen gives no trace sample")
        let ids = { (key: String) in (sample[key] ?? []).compactMap { ($0 as? [Any])?.first as? String } }
        #expect(!ids("panes").contains("p2"), "the closing pane is in the live panes: \(ids("panes"))")
        let row = try #require((sample["closing"] ?? []).compactMap { $0 as? [Any] }.first { $0.first as? String == "p2" },
                               "the trace does not report the closing pane: \(sample.keys.sorted())")
        let rect = row.dropFirst().prefix(4).compactMap { $0 as? Double }
        try #require(rect.count == 4, "the closing row has no rect: \(row)")
        let shown = host.convert(host.bounds, to: nil)
        #expect(abs(rect[0] - shown.minX) < 1 && abs(rect[2] - shown.width) < 1,
                "the closing row \(rect) is not where its ground shows \(shown)")
    }

    static func check(_ root: SplitNode, closing pane: PaneID, kept kind: DividerHandleView.Kind) throws {
        try check(layout: PaneGroundCoversPaneTests.column(root), focused: pane, closing: pane, kept: kind)
    }

    /// Closes `pane` and checks `kind` in the close's first frame, each spring frame and at rest.
    static func check(layout: ScreenLayout, focused: PaneID, closing pane: PaneID, kept kind: DividerHandleView.Kind) throws {
        let rig = Rig(layout, focused: focused)
        defer { rig.close() }
        let screen = try rig.screen
        try #require(screen.dividerViews[kind] != nil, "SETUP: no handle \(kind) before the close")
        try #require(offCentre(kind, in: screen, "at rest before the close") == nil, "SETUP: \(offCentre(kind, in: screen, "at rest") ?? "")")
        _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        var misses = [offCentre(kind, in: screen, "the close's first frame")].compactMap { $0 }
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            if let miss = offCentre(kind, in: screen, "frame \(frames)") { misses.append(miss) }
        }
        rig.commit()
        if let miss = offCentre(kind, in: screen, "at rest after the close") { misses.append(miss) }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(misses.isEmpty, "\(misses.count) of \(frames + 2) frames show the handle \(kind) off its gap: \(misses.prefix(4))")
    }

    /// Nil when the handle `kind` shows in the middle of a gap no pane host covers (within `slack` points); else why not.
    static func offCentre(_ kind: DividerHandleView.Kind, in screen: ScreenContentView, _ label: String, slack: CGFloat = 1) -> String? {
        guard let handle = screen.dividerViews[kind], !handle.isHidden else { return "\(label): the handle is not shown" }
        let shown = handle.convert(handle.bounds, to: nil), bounds = screen.convert(screen.bounds, to: nil)
        // A handle that divides along x (a vertical line) has its gap along the horizontal line through its middle.
        let alongX = handle.axis == .horizontal
        let centre = alongX ? shown.midX : shown.midY, line = alongX ? shown.midY : shown.midX
        var runs = [alongX ? (bounds.minX, bounds.maxX) : (bounds.minY, bounds.maxY)]
        for host in screen.subviews.compactMap({ $0 as? PaneHostView }) where !host.isHidden && host.alphaValue > 0.01 {
            let rect = host.convert(host.bounds, to: nil)
            let (lo, hi) = alongX ? (rect.minX, rect.maxX) : (rect.minY, rect.maxY)
            let (crossLo, crossHi) = alongX ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX)
            guard crossLo <= line, crossHi >= line else { continue }
            runs = runs.flatMap { run in [(run.0, min(run.1, lo)), (max(run.0, hi), run.1)].filter { $0.1 - $0.0 > 0 } }
        }
        let format = { (value: CGFloat) in String(format: "%.1f", value) }
        guard let run = runs.first(where: { $0.0 <= centre && centre <= $0.1 }) else {
            return "\(label): its centre \(format(centre)) is on a pane"
        }
        let off = centre - (run.0 + run.1) / 2
        return abs(off) <= slack ? nil : "\(label): \(format(off)) pt off the middle of its gap \(format(run.0))...\(format(run.1))"
    }
}
