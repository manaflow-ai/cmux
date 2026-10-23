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
    @Test(arguments: ["split", "splitDown"])
    func aSplitFrameTouchesOnlyThePanesItMoves(_ action: String) async throws {
        let harness = PaneMotionBench.Harness(PaneMotionBench.grid(6, 5), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        harness.model.apply(screens: PaneMotionBench.split(6, 5, axis: action == "split" ? .horizontal : .vertical))
        // The change's own frame (the reconcile, which re-places everything once) is not a motion frame.
        _ = await harness.frame()
        var frames = 0, worstOverlay = 0, worstClips = 0, still = 0
        var moving = true
        while moving, frames < 240 {
            // A pane counts as changed in a frame when its host's frame or alpha changed in it...
            let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
            let before = Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), ($0.frame, $0.alphaValue)) })
            let coversBefore = screen.panesAbove()
            let overlay = harness.root.overlayHostsPlaced, clips = screen.stripClipsComputed
            let next = await harness.frame()
            moving = next.moving
            frames += 1
            // ...or when what covers it changed (a pane springing over it): its clip and ring change too.
            let coversAfter = screen.panesAbove()
            let moved = hosts.filter { host in
                let id = ObjectIdentifier(host)
                return before[id].map { $0 != (host.frame, host.alphaValue) } ?? true || coversBefore[id] != coversAfter[id]
            }.count
            still = max(still, hosts.count - moved)
            worstOverlay = max(worstOverlay, harness.root.overlayHostsPlaced - overlay - moved)
            worstClips = max(worstClips, screen.stripClipsComputed - clips - moved)
        }
        #expect(frames > 3, "the split sprang: \(frames) frames")
        #expect(still > 0, "every pane moved on every frame: nothing to tell apart")
        #expect(worstOverlay <= 0, "a frame placed \(worstOverlay) rings of panes that did not move")
        #expect(worstClips <= 0, "a frame computed \(worstClips) strip clips of panes that did not move")
    }
}
