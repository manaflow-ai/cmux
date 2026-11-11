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

    /// The time between two closes, in frames at 120 Hz, from 50 ms to past the first close's landing (about 160 ms; the
    /// loop then closes the second pane at rest).
    nonisolated static let gaps = [6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 22]

    /// MOTION TOKENS CLEANUP, the ground rule for any time between two last-column closes (the layout of
    /// `twoLastColumnClosesInARowLeaveNoGroundPastTheStrip`, which closes six frames apart only). The second close finds its
    /// neighbour, the second column, at the end of the first close's travel: a part of a point from its place to more than
    /// twenty points. The third pane closes over that travel, however short it is, or goes at once when there is none, and
    /// the frame before the landing shows under a point of its ground.
    @Test(arguments: gaps) func twoLastColumnClosesAnyTimeApartLeaveNoGroundPastTheStrip(every: Int) throws {
        let rig = Rig(ColumnCloseScrollMotionTests.columns(4, width: 0.3), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        try #require(screen.scroll.value > 100, "SETUP: the camera does not show the fourth column (offset \(screen.scroll.value))")
        try Self.check(rig, closing: ["p4", "p3"], every: every, vertical: false, landsWithin: 24) {
            try #require(screen.hasMotion, "SETUP: the close does not move the strip")
        }
    }

    /// The same closes as a key press makes them (`PaneController.closePane`: `syncWithModelForNextFrame`, which holds the
    /// presentation for the next frame tick). The closing panes are first placed one spring step after the close's turn
    /// decided which of them a neighbour moves over, so the two must read the neighbours at the same time: a neighbour
    /// with a little more than half a point to go in the turn has less than that a step later.
    @Test(arguments: gaps) func twoLastColumnClosesByKeyAnyTimeApartLeaveNoGroundPastTheStrip(every: Int) throws {
        let rig = Rig(ColumnCloseScrollMotionTests.columns(4, width: 0.3), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        try #require(screen.scroll.value > 100, "SETUP: the camera does not show the fourth column (offset \(screen.scroll.value))")
        try #require(rig.root.isLive && rig.root.driver.isAttached, "SETUP: the root runs no frames, so the key's turn holds nothing")
        try Self.check(rig, closing: ["p4", "p3"], every: every, vertical: false, landsWithin: 24, byKey: true) {
            try #require(screen.hasMotion, "SETUP: the close does not move the strip")
        }
    }

    /// The same for two last-row closes (the layout of `twoLastRowClosesInARowLeaveNoHole`): the second close gives the row
    /// scroll a new target a whole row away, so the first closing pane's travel is never short.
    @Test(arguments: gaps) func twoLastRowClosesAnyTimeApartLeaveNoGround(every: Int) throws {
        let rig = Rig(ColumnCloseScrollMotionTests.rows([400, 400, 400, 400, 400]), focused: "p5")
        defer { rig.close() }
        let screen = try rig.screen
        try #require((screen.rowScrolls["c1"]?.state.spring.value ?? 0) > 100, "SETUP: the rows do not show the fifth")
        try Self.check(rig, closing: ["p5", "p4"], every: every, vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
    }

    /// The same where the second last-row close makes the rows fit (the layout of
    /// `aSecondLastRowCloseThatMakesTheRowsFitLeavesNoGround`): the row scroll goes with the second close.
    @Test(arguments: gaps) func aSecondLastRowCloseThatMakesTheRowsFitAnyTimeApartLeavesNoGround(every: Int) throws {
        let rig = Rig(ColumnCloseScrollMotionTests.rows([400, 400, 400, 400]), focused: "p4")
        defer { rig.close() }
        let screen = try rig.screen
        try #require((screen.rowScrolls["c1"]?.state.spring.value ?? 0) > 100, "SETUP: the rows do not show the fourth")
        try Self.check(rig, closing: ["p4", "p3"], every: every, vertical: true) {
            let after = try #require(screen.rowScrolls["c1"]?.state.spring, "SETUP: the rows stopped scrolling at the first close")
            try #require(abs(after.target - after.value) > 0.5, "SETUP: the row scroll does not spring back (\(after.value) -> \(after.target))")
        }
    }

    /// Closes `panes`, each `every` frames after the one before, and checks each frame along the line through the window's
    /// middle (`vertical`: top to bottom, else left to right). `moving`: the SETUP checks after the first close's turn.
    /// `landsWithin`: the most frames from the last close to the landing (the landing waits for the closing panes' free
    /// sides, and must not wait longer than a close takes: 24 frames are 200 ms at 120 Hz). `byKey`: each close is shown
    /// by the next frame tick, as a key press's is (`LayoutRootView.syncWithModelForNextFrame`), not in its own turn.
    static func check(_ rig: Rig, closing panes: [PaneID], every: Int = 6, vertical: Bool, landsWithin: Int? = nil, byKey: Bool = false,
                      moving: () throws -> Void) throws {
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
        /// The closing ground of each frame after the last close (what the failure text shows of the way to the landing).
        var grounds: [CGFloat] = []
        /// What the last frame with a closing ground showed, for the failure text: the strip camera and each shown host.
        var lastGroundFrame = ""
        var frames = 0, lastClose = 0
        for (index, pane) in panes.enumerated() {
            lastClose = frames
            _ = try #require(rig.model.showPaneClose(pane), "\(pane) did not close")
            if byKey { rig.root.syncWithModelForNextFrame() } else { rig.root.syncWithModel() }
            rig.root.layoutSubtreeIfNeeded()
            if index == 0 { try moving() }
            widths.append((frames, uncovered()))
            let until = index == panes.count - 1 ? 240 : frames + every
            while frames < until, rig.frame() {
                frames += 1
                widths.append((frames, uncovered()))
                // What of the line only closing grounds cover: in the landing's frame it is gone at once.
                if closing.contains(where: { $0.superview != nil && !$0.isHidden && $0.showsClosingGround }) {
                    let ground = uncovered(liveOnly: true) - uncovered()
                    lastGround = ground
                    if index == panes.count - 1 { grounds.append(ground) }
                    var shown: [String] = []
                    for case let host as PaneHostView in screen.subviews where !host.isHidden && host.alphaValue > 0.01 {
                        let kind: String = host.showsClosingGround ? " closing" : ""
                        shown.append("\(host.pane)\(kind) x \(host.frame.minX)...\(host.frame.maxX)")
                    }
                    let camera: String = "camera \(screen.scroll.value) -> \(screen.scroll.target)"
                    lastGroundFrame = "frame \(frames), scale \(screen.scale), \(camera), " + shown.sorted().joined(separator: "; ")
                }
            }
        }
        rig.commit()
        let rest = uncovered()
        let open = widths.filter { $0.width > max(atRest, rest) + 1 }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show the shell in the window (\(atRest) pt before, \(rest) pt after): \(open.prefix(4))")
        // Under one point, the bound before #40288. Measured at dfc699991f16 (aws-m4pro-2, macOS 27.0.1, scale 1; no spring
        // is under-damped since #40288): two last-column closes 7 to 12 frames apart left 2, 3, 4, 7, 13 and 22 pt in the
        // last frame, and 13 to 16 frames apart the whole pane, 352 pt. A closing pane's free side follows its rider's
        // share of the rider's travel (`ClosingPanesRules.collapse`), so what a live pane has left when the motion lands
        // shows on the closing pane times its size over that travel, and a rider with under half a point to go gives it
        // no travel. The landing now waits for the closing panes' free sides as it does for the live edges, and a pane
        // beside panes with under half a point to go goes at once (`ClosingPanes.landingMovesAClosingPane`, `hasTravel`).
        if let lastGround {
            let way = grounds.suffix(8).map { String(format: "%.2f", Double($0)) }.joined(separator: ", ")
            #expect(lastGround < 1, """
            the closing panes' last frame shows \(lastGround) pt of their ground: the landing takes it away \
            (\(lastGroundFrame); the ground of the last frames, in points: \(way))
            """)
        }
        if let landsWithin {
            #expect(frames - lastClose <= landsWithin, "the motion landed \(frames - lastClose) frames after the last close (at most \(landsWithin))")
        }
        #expect(closing.allSatisfy { $0.superview == nil }, "a closed host is left in the tree after the landing")
    }
}
