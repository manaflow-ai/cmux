import AppKit
@testable import CmuxNextLayout
import Testing

/// Per-frame layout work is O(the panes that moved), not O(all panes) (perf-lead issue 3,
/// structural cause 1). A split in the first column of a 6 x 5 grid moves two panes; every other
/// frame of its spring must leave the other 28 panes' rings, dims, window frames and clips alone.
/// Run with the pane bench (CMUX_PANE_BENCH=1, `nx-remote --needs xcode27`): not a CI gate.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CMUX_PANE_BENCH"] == "1"))
struct PaneMotionWorkTests {
    /// The two panes the split moves, and one for the pane that arrives.
    static let movedPanes = 3

    @Test(arguments: ["split", "splitDown"])
    func aSplitFrameTouchesOnlyThePanesItMoves(_ action: String) async throws {
        let harness = PaneMotionBench.Harness(PaneMotionBench.grid(6, 5), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        harness.model.apply(screens: PaneMotionBench.split(6, 5, axis: action == "split" ? .horizontal : .vertical))
        // The change's own frame (the reconcile, which re-places everything once) is not a motion frame.
        _ = await harness.frame()
        var frames = 0, worstOverlay = 0, worstClips = 0
        var moving = true
        while moving, frames < 240 {
            let overlay = harness.root.overlayHostsPlaced, clips = screen.stripClipsComputed
            let next = await harness.frame()
            moving = next.moving
            frames += 1
            worstOverlay = max(worstOverlay, harness.root.overlayHostsPlaced - overlay)
            worstClips = max(worstClips, screen.stripClipsComputed - clips)
        }
        #expect(frames > 3, "the split sprang: \(frames) frames")
        #expect(worstOverlay <= Self.movedPanes, "a frame placed \(worstOverlay) rings of 31 panes; the split moves \(Self.movedPanes)")
        #expect(worstClips <= Self.movedPanes, "a frame computed \(worstClips) strip clips of 31 panes; the split moves \(Self.movedPanes)")
    }
}
