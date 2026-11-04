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
        try Self.check(rig, closing: ["p3"], vertical: false) {
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
        try Self.check(rig, closing: ["p4"], vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
    }

    /// Two last-row closes in a row (Cmd-W twice): five rows scrolled to the fifth, the fifth closes, and six frames later
    /// the fourth, while the row scroll still springs back for the first. The second close takes the scroll to another
    /// target, and the first closing pane rides the second: neither leaves the shell between them, below them, or for the
    /// landing.
    @Test func twoLastRowClosesInARowLeaveNoHole() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.rows([400, 400, 400, 400, 400]), focused: "p5")
        defer { rig.close() }
        let screen = try rig.screen
        let before = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the column's rows do not scroll")
        try #require(before.value > 100, "SETUP: the rows do not show the fifth (offset \(before.value))")
        try Self.check(rig, closing: ["p5", "p4"], vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
    }

    /// Two last-column closes in a row past the strip's end (Codex review, round 2): four 0.3-wide columns (new columns
    /// keep their width), the camera at the end on the fourth, the fourth closes, and six frames later the third. The strip
    /// fits after the first close and leaves an empty end after the second. The fourth closing pane rides the third, a
    /// closing pane: it must collapse onto where the third rests (in the strip, beside the second column), not keep the
    /// ground it showed in the strip's empty end for the landing to take away in one frame.
    @Test func twoLastColumnClosesInARowLeaveNoGroundPastTheStrip() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.columns(4, width: 0.3), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        try #require(screen.scroll.value > 100, "SETUP: the camera does not show the fourth column (offset \(screen.scroll.value))")
        try Self.check(rig, closing: ["p4", "p3"], vertical: false) {
            try #require(screen.hasMotion, "SETUP: the close does not move the strip")
        }
    }

    /// Two last-row closes in a row where the second makes the rows fit (Codex review, round 2; a guard: rows that fit fill
    /// their column, so the frozen edge of the old code was already at its rest): four 400-permille rows scrolled to the
    /// fourth, the fourth closes, and six frames later the third. The two rows left fit the column, so its scroll goes; the
    /// first closing pane rides the second, which collapses onto the second row's rest, and leaves no ground for the
    /// landing.
    @Test func aSecondLastRowCloseThatMakesTheRowsFitLeavesNoGround() throws {
        let rig = Rig(ColumnCloseScrollMotionTests.rows([400, 400, 400, 400]), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        try #require((screen.rowScrolls["c1"]?.state.spring.value ?? 0) > 100, "SETUP: the rows do not show the fourth")
        try Self.check(rig, closing: ["p4", "p3"], vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling at the first close")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
        #expect(screen.rowScrolls["c1"] == nil, "SETUP: two rows still scroll after the second close")
    }

    /// Closes `panes`, each `every` frames after the one before, and checks each frame along the line through the window's
    /// middle (`vertical`: top to bottom, else left to right). `moving`: the SETUP checks after the first close's turn.
    static func check(_ rig: Rig, closing panes: [PaneID], every: Int = 6, vertical: Bool, moving: () throws -> Void) throws {
        let screen = try rig.screen
        let bounds = screen.convert(screen.bounds, to: nil)
        func span(_ rect: CGRect) -> (CGFloat, CGFloat) { vertical ? (rect.minY, rect.maxY) : (rect.minX, rect.maxX) }
        /// What of the line no shown pane host covers (live or closing; `liveOnly`: live), in points.
        func uncovered(liveOnly: Bool = false) -> CGFloat {
            let line = vertical ? bounds.midX : bounds.midY
            var gaps = [span(bounds)]
            let hosts = screen.subviews.compactMap { $0 as? PaneHostView }.filter { !$0.isHidden && $0.alphaValue > 0.01 }
            for host in hosts where !(liveOnly && host.showsClosingGround) {
                let shown = host.convert(host.bounds, to: nil)
                let (crossLo, crossHi) = vertical ? (shown.minX, shown.maxX) : (shown.minY, shown.maxY)
                guard crossLo <= line, crossHi >= line else { continue }
                let (lo, hi) = span(shown)
                gaps = gaps.flatMap { gap in [(gap.0, min(gap.1, lo)), (max(gap.0, hi), gap.1)].filter { $0.1 - $0.0 > 0 } }
            }
            return gaps.reduce(0) { $0 + ($1.1 - $1.0) }
        }
        let atRest = uncovered()
        let closing = try panes.map { try #require(rig.root.context.hosts[$0], "SETUP: no host for \($0)") }
        var widths: [(frame: Int, width: CGFloat)] = []
        var lastGround: CGFloat?
        var frames = 0
        for (index, pane) in panes.enumerated() {
            _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close")
            rig.root.syncWithModel()
            rig.root.layoutSubtreeIfNeeded()
            if index == 0 { try moving() }
            widths.append((frames, uncovered()))
            let until = index == panes.count - 1 ? 240 : frames + every
            while frames < until, rig.frame() {
                frames += 1
                widths.append((frames, uncovered()))
                // What of the line only closing grounds cover: in the landing's frame it is gone at once.
                if closing.contains(where: { $0.superview != nil && !$0.isHidden && $0.showsClosingGround }) {
                    lastGround = uncovered(liveOnly: true) - uncovered()
                }
            }
        }
        rig.commit()
        let rest = uncovered()
        let open = widths.filter { $0.width > max(atRest, rest) + 1 }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show the shell in the window (\(atRest) pt before, \(rest) pt after): \(open.prefix(4))")
        if let lastGround { #expect(lastGround < 1, "the closing panes' last frame shows \(lastGround) pt of their ground: the landing takes it away") }
        #expect(closing.allSatisfy { $0.superview == nil }, "a closed host is left in the tree after the landing")
    }
}
