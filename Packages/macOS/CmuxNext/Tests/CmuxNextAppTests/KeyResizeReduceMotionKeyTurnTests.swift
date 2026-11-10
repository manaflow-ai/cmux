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
/// RESIZE P0 13 (KEY SNAP GRID) made such a press wait for the next frame tick, so its key's turn could draw each resized
/// terminal's size ahead with its grid. GI RENDERER SYNC (#40174) deleted that draw-ahead: Ghostty's renderer now holds a
/// frame of the old size until the program's redraw at the new one (`GHOSTTY_HOST_PRESENT_RENDERER_SYNCED`, design
/// `ghostty-integration.md` 4.1 and 4.3: "Reduce Motion and 'no animation' snap in one frame"). The tick wait had nothing
/// left to wait for, so a press that starts no spring presents in the key's own turn again (GI RENDERER SYNC 2, item 2).
///
/// The rig's driver is manual: the test steps the one frame tick.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeReduceMotionKeyTurnTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// Reduce Motion, then pane animations off: each press moves p2's host in the key's own turn, and nothing is left
    /// waiting for a frame tick. The next tick moves it no further.
    @Test(arguments: [true, false])
    func aPressWithNoSpringMovesThePaneInTheKeysOwnTurn(reduceMotion: Bool) throws {
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
            let moved = host.frame
            #expect(moved != before, "a \(direction) press with no spring did not move p2 in the key's own turn (\(before))")
            #expect(!(try rig.screen.frameInput.presentationWaiting), "a \(direction) press with no spring left its presentation waiting for a frame tick")
            _ = rig.frame()
            #expect(host.frame == moved, "a \(direction) press with no spring moved p2 again at the next frame tick (\(moved) -> \(host.frame))")
        }
    }
}
