import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import Testing

/// FRAME OWNER REFACTOR S1B, #34380's key turn under Reduce Motion (and with pane animations off). The key's turn holds
/// the presentation for the press's first frame tick only when the press starts a spring. A press that starts none (its
/// frames snap) has no tick that moves it, so it presents in the key's own turn, as before #34380. Found by
/// `TerminalSurfaceCommitSizeTests.aReduceMotionKeyResizeNeverHoldsTheMainThreadForTheTerminals`: at #34380's head the
/// press moved nothing (base de82e16a37a: passes, step 7487a3eaf2de6c92df4831e4; head b89a454f689: fails, step
/// 371efb4af257d839a96202ef).
///
/// RESIZE P0 13 (KEY SNAP GRID): such a press now shows at the next frame tick, as a snapped structural change does
/// (CLOSE MOTION 3, `ScreenContentView+SnapFrame`): its key's turn gives each resized terminal its size ahead with its grid,
/// so the program redraws before the tick shows the press (``ReduceMotionKeyResizeGridTests``). It still never waits for
/// a spring: the next tick shows it, and it asks for that tick.
///
/// The rig's driver is manual: the test steps the one frame tick.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeReduceMotionKeyTurnTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// Reduce Motion, then pane animations off: each press moves p2's host at the next frame tick (not in the key's turn,
    /// where its terminal gets its size ahead with its grid), and that one tick shows it all: nothing is left waiting.
    @Test(arguments: [true, false])
    func aPressWithNoSpringMovesThePaneAtTheNextFrameTick(reduceMotion: Bool) throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.reduceMotionOverride = reduceMotion ? true : nil
        // Pane animations off (`ui.paneAnimations`): the key's width change snaps (Reduce Motion may be on too on the host).
        let paneAnimations = DesignSettings.shared.paneAnimations
        if !reduceMotion { DesignSettings.shared.paneAnimations = false }
        defer { DesignSettings.shared.paneAnimations = paneAnimations }
        try #require(rig.root.context.reduceMotion || !rig.root.context.animatesPaneLayout, "the press would spring")
        let host = try #require(rig.root.context.hosts["p2"])
        for direction in [LayoutDirection.left, .right, .left] {
            let before = host.frame
            #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
            #expect(host.frame == before, "a \(direction) press with no spring moved p2 in the key's turn, before its terminal had its grid")
            #expect(try rig.screen.frameInput.presentationWaiting, "a \(direction) press with no spring did not wait for the next frame tick")
            _ = rig.frame()
            #expect(host.frame != before, "a \(direction) press with no spring did not move p2 at the next frame tick (\(before))")
            #expect(!(try rig.screen.frameInput.presentationWaiting), "a \(direction) press with no spring left its presentation waiting after the tick")
        }
    }
}
