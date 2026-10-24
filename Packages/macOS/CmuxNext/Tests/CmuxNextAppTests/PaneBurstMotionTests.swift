import AppKit
import CmuxNextDesignTokens
@testable import CmuxNextLayout
import Testing

/// A burst of presses (Lawrence 2026-10-24: spamming Cmd-D / Cmd-W lags and does not interrupt well): a split
/// or close that lands while a spring runs retargets from what shows, with no jump and no extra step.
@MainActor
@Suite struct PaneBurstMotionTests {
    /// Four columns side by side; `closed` leaves the named columns out.
    static func row(_ count: Int, without closed: Set<Int> = []) -> [LayoutScreen] {
        let kept = (0..<count).filter { !closed.contains($0) }
        let columns = kept.map { PaneMotionBench.column($0, rows: 1, width: 1.0 / Double(kept.count)) }
        return [LayoutScreen(id: "s", name: "s", layout: .columns(columns))]
    }

    /// M1 (PL-burst): a close's lead step (its first frame taken in the change's own turn) is for a close that
    /// starts from rest. A second close while the first one springs must not step the moving panes again in its
    /// turn: they keep showing where they were, and the next display frame moves them by one frame's step.
    @Test func aCloseDuringASpringDoesNotStepTheMovingPanesInItsTurn() async throws {
        let harness = PaneMotionBench.Harness(Self.row(4), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        harness.model.apply(screens: Self.row(4, without: [1]))
        harness.root.syncWithModel()
        for _ in 0..<5 { _ = harness.root.advanceFrame(PaneMotionBench.frameBudget) }
        let pane = PaneID("p3-0")
        let moving = try #require(screen.paneFrames[pane])
        #expect(moving.rect != moving.targetRect, "the first close is not springing")
        let shown = moving.rect
        harness.model.apply(screens: Self.row(4, without: [1, 2]))
        harness.root.syncWithModel()
        let after = try #require(screen.paneFrames[pane]).rect
        #expect(after == shown, "the second close stepped a moving pane in its own turn: \(shown) -> \(after)")
    }

    /// M4 (PL-burst): a divider released with a velocity seeds only the frames its layout change moves; a pane
    /// already springing for another reason (a column closing elsewhere) keeps its own velocity.
    @Test func aDividerReleaseSeedsOnlyTheFramesItMoves() throws {
        var frames: [PaneID: AnimatedFrame] = [:]
        var moving = AnimatedFrame(CGRect(x: 0, y: 0, width: 100, height: 100))
        moving.setTarget(CGRect(x: 0, y: 0, width: 300, height: 100))
        moving.width.velocity = 777
        frames[PaneID("unrelated")] = moving
        var released = AnimatedFrame(CGRect(x: 0, y: 0, width: 200, height: 100))
        released.setTarget(CGRect(x: 0, y: 0, width: 260, height: 100))
        frames[PaneID("beside")] = released
        var divider = AnimatedFrame(CGRect(x: 200, y: 0, width: 4, height: 100))
        divider.setTarget(CGRect(x: 260, y: 0, width: 4, height: 100))
        var dividers: [DividerHandleView.Kind: AnimatedFrame] = [.split(SplitID("d")): divider]
        SplitMotion.seed(velocity: 600, along: .horizontal, divider: divider, panes: &frames, dividers: &dividers,
                         moved: [PaneID("beside")])
        #expect(frames[PaneID("unrelated")]?.width.velocity == 777, "the release reset a spring it does not move")
        #expect((frames[PaneID("beside")]?.width.velocity ?? 0) > 0, "the pane beside the divider was not seeded")
    }

    /// M2 (PL-burst): the screen resized while a spring runs (the sidebar sliding, the screen bar toggling) keeps
    /// the spring going toward the new rest from where the panes show; it does not snap them to their end.
    @Test func aResizeDuringASpringKeepsItGoing() async throws {
        let harness = PaneMotionBench.Harness(Self.row(4), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        harness.model.apply(screens: Self.row(4, without: [1]))
        harness.root.syncWithModel()
        for _ in 0..<4 { _ = harness.root.advanceFrame(PaneMotionBench.frameBudget) }
        let shown = try #require(screen.paneFrames[PaneID("p3-0")]).rect
        screen.setFrameSize(NSSize(width: screen.frame.width - 200, height: screen.frame.height))
        let frame = try #require(screen.paneFrames[PaneID("p3-0")])
        #expect(frame.rect == shown, "the resize moved a springing pane in its turn: \(shown) -> \(frame.rect)")
        #expect(screen.hasMotion, "the resize snapped the spring to its end")
    }
}
