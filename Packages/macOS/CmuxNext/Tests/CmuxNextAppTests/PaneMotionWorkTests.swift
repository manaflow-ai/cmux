import AppKit
@testable import CmuxNextLayout
import Testing

/// Per-frame layout work is O(the panes that moved), not O(all panes) (perf-lead issue 3,
/// structural cause 1). A split in the first column of a 6 x 5 grid moves two panes; every other
/// frame of its spring must leave the other 28 panes' rings, dims, window frames and clips alone.
/// Run with the pane bench (CMUX_PANE_BENCH=1, `nx-remote --needs xcode27`): not a CI gate.
@MainActor
@Suite(.serialized)
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

    /// Review 2 of PL-motion-core: each motion frame walked `panesAbove()` (O(n²) in the hosts)
    /// twice, in the presentation pass and the overlay sync, and again on frames at rest. One
    /// frame now walks it at most once, and a frame where no host moved walks it not at all.
    @Test func aMotionFrameWalksThePanesAboveAtMostOnce() async throws {
        let harness = PaneMotionBench.Harness(PaneMotionBench.grid(6, 5), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        harness.model.apply(screens: PaneMotionBench.split(6, 5, axis: .horizontal))
        _ = await harness.frame()
        var frames = 0, worst = 0, moving = true
        while moving, frames < 240 {
            let walks = screen.panesAboveMemo.walks
            moving = await harness.frame().moving
            frames += 1
            worst = max(worst, screen.panesAboveMemo.walks - walks)
        }
        #expect(frames > 3, "the split sprang: \(frames) frames")
        #expect(worst <= 1, "a motion frame walked the panes above \(worst) times")
        let walks = screen.panesAboveMemo.walks
        _ = screen.panesAbove()
        #expect(screen.panesAboveMemo.walks == walks, "a frame at rest walked the panes above again")
    }

    /// New Column at 30 panes: the strip camera moves every pane sideways at its size. A pane that
    /// only moves lays out no clip and no content on any frame (no strip layout, no terminal resize).
    @Test func panesThatOnlyMoveLayOutNothing() async throws {
        let harness = PaneMotionBench.Harness(PaneMotionBench.grid(6, 5), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
        let sizes = Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), $0.frame.size) })
        let before = Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), $0.clipLayouts) })
        var origins = Set<ObjectIdentifier>()
        let start = Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), $0.frame.origin) })
        // The new column takes focus, as New Column's does: the camera reveals it and every pane slides.
        harness.model.apply(screens: PaneMotionBench.grid(6, 5, extraColumn: true))
        harness.model.focus(PaneID("p6-0"), notify: false)
        var moving = true, frames = 0
        while moving, frames < 240 {
            moving = await harness.frame().moving
            frames += 1
            for host in hosts where host.frame.origin != start[ObjectIdentifier(host)] { origins.insert(ObjectIdentifier(host)) }
        }
        let still = hosts.filter { $0.frame.size == sizes[ObjectIdentifier($0)] && origins.contains(ObjectIdentifier($0)) }
        let laidOut = still.reduce(0) { $0 + $1.clipLayouts - (before[ObjectIdentifier($1)] ?? 0) }
        #expect(!still.isEmpty, "New Column moved no pane at its size")
        #expect(laidOut == 0, "\(still.count) panes that only moved laid out \(laidOut) times over \(frames) frames")
    }
}
