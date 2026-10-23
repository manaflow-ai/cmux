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
