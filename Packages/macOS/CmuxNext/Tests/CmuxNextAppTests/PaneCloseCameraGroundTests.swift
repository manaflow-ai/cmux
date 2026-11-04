import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTabs
@testable import CmuxNextTerminal
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S3c, the close of the last column of a strip (film P12, the close of a new column: the closed
/// column's place showed the shell as the camera moved back, about 700 -> 10 px over 22 frames). Three half-width columns,
/// the camera at the end on the third, and Cmd-W on it: two columns stay (a strip of one column becomes a split screen,
/// whose pane slides in on its own spring), so no pane frame moves and only the strip camera springs back. In every frame
/// the window's width is covered by pane hosts (the closing pane with its own ground, the live ones sliding in) beyond the
/// gaps that show at rest, and the closing pane leaves no ground for the landing to take away in one frame.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct PaneCloseCameraGroundTests {
    typealias Rig = PaneGroundCoversPaneTests.Rig

    @Test func closingTheLastColumnWhileTheCameraMovesBackLeavesNoHole() throws {
        let rig = Rig(Self.threeColumns, focused: "p3")
        defer { rig.close() }
        rig.root.context.contentPolicyOverride = true
        let screen = try rig.screen
        let line = screen.convert(screen.bounds, to: nil)
        let atRest = try rig.uncoveredWidth(of: line)
        try #require(atRest < 20, "SETUP: \(atRest) pt of the window is not covered at rest")
        let closing = try #require(rig.root.context.hosts["p3"])
        try #require(screen.scroll.value > 100, "SETUP: the camera does not show the right column (offset \(screen.scroll.value))")
        _ = try #require(rig.model.showPaneClose("p3"), "p3 did not close")
        rig.root.syncWithModel()
        rig.root.layoutSubtreeIfNeeded()
        try #require(screen.scroll.value != screen.scroll.target, "SETUP: the camera does not move back for the close")
        var widths: [(frame: Int, width: CGFloat)] = [(0, try rig.uncoveredWidth(of: line))]
        var lastGround: CGFloat?
        var frames = 0
        while frames < 240, rig.frame() {
            frames += 1
            widths.append((frames, try rig.uncoveredWidth(of: line)))
            if closing.superview != nil, !closing.isHidden {
                let ground = closing.convert(closing.bounds, to: nil).intersection(line)
                let live = try #require(rig.root.context.hosts["p2"])
                let covered = ground.intersection(live.convert(live.bounds, to: nil))
                lastGround = max(0, ground.width - (covered.isNull ? 0 : covered.width))
            }
        }
        rig.commit()
        let rest = try rig.uncoveredWidth(of: line)
        let open = widths.filter { $0.width > max(atRest, rest) + 1 }
        #expect(frames > 3, "the close did not spring (\(frames) frames)")
        #expect(open.isEmpty, "\(open.count) frames show the shell in the window (\(atRest) pt before, \(rest) pt after): \(open.prefix(4))")
        if let lastGround { #expect(lastGround < 1, "the closing pane's last frame shows \(lastGround) pt of its ground: the landing takes it away") }
        #expect(closing.superview == nil, "the closed host is left in the tree after the landing")
    }

    /// Three half-width columns: two fit the window, three scroll.
    static let threeColumns: ScreenLayout = .columns((1...3).map { LayoutColumn(id: ColumnID("c\($0)"), width: 0.5, root: .leaf(PaneID("p\($0)"))) })
}
