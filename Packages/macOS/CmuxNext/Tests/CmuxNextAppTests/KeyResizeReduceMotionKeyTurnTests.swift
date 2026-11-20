import AppKit
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextDesign
@testable import CmuxNextLayout
@testable import CmuxNextTerminal
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
/// RESIZE P0 21 (#38206, 67479c6b6cb): a key press's held snap also waits while a size drawn ahead for it has not gone to
/// Ghostty. That size goes in the terminal presenter's pass, a run-loop observer at the end of the key's turn, so the
/// test ends the key's turn as the main run loop does before it steps the tick. Before, the test stepped the tick inside
/// the key's turn: the snap waited for that pass, and the tick showed nothing.
///
/// The rig's driver is manual: the test ends the key's turn and steps the one frame tick. For its last press it ends no
/// turn and steps the ticks of the wait's bound.
@MainActor
@Suite(.serialized, .closesItsWindows)
struct KeyResizeReduceMotionKeyTurnTests {
    typealias Ground = PaneGroundCoversPaneTests

    /// Reduce Motion, then pane animations off: each press moves p2's host at the next frame tick (not in the key's turn,
    /// where its terminal gets its size ahead with its grid), and that one tick shows it all: nothing is left waiting.
    /// Then one press whose key's turn never ends (no presenter pass comes between the ticks, as when a real key and the
    /// display tick run in one wake of the main run loop): the snap's wait for that pass is bounded, so the press shows
    /// within ``TerminalFramePresenter/resizeHoldTicks`` + 1 ticks.
    @Test(arguments: [true, false])
    func aPressWithNoSpringMovesThePaneAtTheNextFrameTick(reduceMotion: Bool) async throws {
        let rig = Ground.Rig(Ground.column(Ground.pair), focused: "p2")
        defer { rig.close() }
        rig.root.context.reduceMotionOverride = reduceMotion ? true : nil
        // Pane animations off (`ui.paneAnimations`): the key's width change snaps (Reduce Motion may be on too on the host).
        let paneAnimations = DesignSettings.shared.paneAnimations
        if !reduceMotion { DesignSettings.shared.paneAnimations = false }
        defer { DesignSettings.shared.paneAnimations = paneAnimations }
        try #require(rig.root.context.reduceMotion || !rig.root.context.animatesPaneLayout, "the press would spring")
        let host = try #require(rig.root.context.hosts["p2"])
        let surfaces = try ["p1", "p2"].map { try PaneContentPolicyTests.surface($0, in: rig) }
        for direction in [LayoutDirection.left, .right, .left] {
            let before = host.frame
            #expect(PaneResize.press("p2", direction, model: rig.model, view: rig.root))
            #expect(host.frame == before, "a \(direction) press with no spring moved p2 in the key's turn, before its terminal had its grid")
            #expect(try rig.screen.frameInput.presentationWaiting, "a \(direction) press with no spring did not wait for the next frame tick")
            #expect(await Self.endKeyTurn(surfaces), "a \(direction) press's sizes drawn ahead did not go to Ghostty in 1 s of main turns")
            #expect(host.frame == before, "a \(direction) press with no spring moved p2 before the next frame tick")
            _ = rig.frame()
            #expect(host.frame != before, "a \(direction) press with no spring did not move p2 at the next frame tick (\(before))")
            #expect(!(try rig.screen.frameInput.presentationWaiting), "a \(direction) press with no spring left its presentation waiting after the tick")
        }
        // No pass comes: nothing is awaited from the press to the last tick, so the main run loop never ends a turn and
        // the size drawn ahead never goes to Ghostty. The snap must not wait for it past its bound.
        let before = host.frame, bound = Int(TerminalFramePresenter.resizeHoldTicks) + 1
        try #require(PaneResize.press("p2", .right, model: rig.model, view: rig.root), "the last press moved nothing")
        // The wait must run for the bound to be the subject: a press that drew no size ahead shows at the first tick.
        #expect(surfaces.contains { $0.frameOwnership.pendingAhead != nil }, "the last press drew no size ahead: the snap has nothing to wait for")
        var ticks = 0
        while host.frame == before, ticks <= bound {
            _ = rig.frame()
            ticks += 1
        }
        #expect(host.frame != before && ticks <= bound,
                "a press whose turn's presenter pass never came: p2 moved \(host.frame != before) in \(ticks) frame ticks; it must move within the bound \(bound)")
    }

    /// The rest of the key's turn, as the main run loop ends it: the presenter's pass before the commit gives Ghostty each
    /// size drawn ahead. A frame of the last tick still on its way to Ghostty keeps that size for a later pass, so turns
    /// go on until no size waits to go (at most 1 s). Whether none waits.
    static func endKeyTurn(_ surfaces: [TerminalSurfaceView]) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            await TerminalKeyResizeFrameTests.commit()
        } while surfaces.contains(where: { $0.frameOwnership.pendingAhead != nil }) && ContinuousClock.now < deadline
        return !surfaces.contains { $0.frameOwnership.pendingAhead != nil }
    }
}
