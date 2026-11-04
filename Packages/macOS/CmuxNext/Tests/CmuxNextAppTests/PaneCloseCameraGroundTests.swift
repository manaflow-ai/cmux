import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3c, the close of the last column of a strip or the last row of a scrolling column (film P12, the
/// close of a new column: the closed column's place showed the shell as the strip shifted back, about 700 -> 10 px over 22
/// frames). In every frame the pane hosts (the closing pane with its own ground, the live ones moving in) cover the
/// window along the line across the closed place beyond the gaps that show at rest, and the closing pane leaves no ground
/// for the landing to take away in one frame.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseCameraGroundTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    /// Three half-width columns, the camera at the end on the third, and Cmd-W on it. Two columns stay (a strip of one
    /// column becomes a split screen): the strip camera clamps to the new end at once and the panes it carries spring back
    /// from where they showed, so the neighbour moves only from the change's camera on (`syncScroll`).
    @Test func closingTheLastColumnWhileTheStripShiftsBackLeavesNoHole() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.columns(3), focused: "p3")
        defer { rig.close() }
        let screen = try rig.screen
        try #require(screen.scroll.value > 100, "SETUP: the camera does not show the right column (offset \(screen.scroll.value))")
        try Self.check(rig, closing: "p3", neighbour: "p2", vertical: false) {
            try #require(screen.hasMotion, "SETUP: the close does not move the strip")
        }
    }

    /// One column of four rows, each 400 permille of its height, scrolled to the fourth, and Cmd-W on it. Three rows still
    /// overflow: the row column's scroll springs back (a row camera keeps its spring) and no pane frame moves.
    @Test func closingTheLastRowWhileTheRowsScrollBackLeavesNoHole() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.rows([400, 400, 400, 400]), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        let before = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the column's rows do not scroll")
        try #require(before.value > 100, "SETUP: the rows do not show the fourth (offset \(before.value))")
        try Self.check(rig, closing: "p4", neighbour: "p3", vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
    }

    /// Closes `pane` and checks each frame along the line through the window's middle (`vertical`: top to bottom, else left
    /// to right). `moving`: the SETUP checks after the close's turn. `neighbour`: the live pane beside the closing one.
    static func check(_ rig: Rig, closing pane: PaneID, neighbour: PaneID, vertical: Bool, moving: () throws -> Void) throws {
        rig.root.context.contentPolicyOverride = true
        let screen = try rig.screen
        let bounds = screen.convert(screen.bounds, to: nil)
        func span(_ rect: CGRect) -> (CGFloat, CGFloat) { vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX) }
        /// What of the line no shown pane host (live or closing) covers, in points.
        func uncovered() -> CGFloat {
            let line = vertical ? bounds.midX : bounds.midY
            var gaps = [span(bounds)]
            for host in screen.subviews.compactMap({ $0 as? PaneHostView }) where !host.isHidden && host.alphaValue > 0.01 {
                let shown = host.convert(host.bounds, to: nil)
                let (crossLo, crossHi) = vertical ? (shown.minX, shown.maxX) : (shown.minY, shown.maxY)
                guard crossLo <= line, crossHi >= line else { continue }
                let (lo, hi) = span(shown)
                gaps = gaps.flatMap { gap in [(gap.0, min(gap.1, lo)), (max(gap.0, hi), gap.1)].filter { $0.1 - $0.0 > 0 } }
            }
            return gaps.reduce(0) { $0 + ($1.1 - $1.0) }
        }
        let atRest = uncovered()
        let closing = try #require(rig.root.context.hosts[pane])
        _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try moving()
        var widths: [(frame: Int, width: CGFloat)] = [(0, uncovered())]
        var lastGround: CGFloat?
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            widths.append((frames, uncovered()))
            if closing.superview != nil, !closing.isHidden, let live = rig.root.context.hosts[neighbour] {
                // The closing ground in the window, less what the live neighbour covers of it.
                let ground = closing.convert(closing.bounds, to: nil).intersection(bounds)
                let (lo, hi) = ground.isNull ? (0, 0) : span(ground), (coverLo, coverHi) = span(live.convert(live.bounds, to: nil))
                lastGround = max(0, hi - lo) - max(0, min(hi, coverHi) - max(lo, coverLo))
            }
        }
        rig.commit()
        let rest = uncovered()
        let open = widths.filter { $0.width > max(atRest, rest) + 1 }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show the shell in the window (\(atRest) pt before, \(rest) pt after): \(open.prefix(4))")
        if let lastGround { #expect(lastGround < 1, "the closing pane's last frame shows \(lastGround) pt of its ground: the landing takes it away") }
        #expect(closing.superview == nil, "the closed host is left in the tree after the landing")
    }
}
