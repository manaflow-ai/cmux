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
        var frames = 0, worstOverlay = 0, worstClips = 0, still = 0, stale = 0
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
            // The lower bound: whatever the sync skipped, every displayed pane's ring sits on its host.
            for host in hosts where host.chrome.superview != nil && !host.isHidden {
                let ring = harness.root.convert(host.bounds, from: host)
                if host.chrome.frame != ring || (host.stripClipInput.map { $0.size != host.frame.size } ?? false) { stale += 1 }
            }
            worstOverlay = max(worstOverlay, harness.root.overlayHostsPlaced - overlay - moved)
            worstClips = max(worstClips, screen.stripClipsComputed - clips - moved)
        }
        #expect(frames > 3, "the split sprang: \(frames) frames")
        #expect(still > 0, "every pane moved on every frame: nothing to tell apart")
        #expect(worstOverlay <= 0, "a frame placed \(worstOverlay) rings of panes that did not move")
        #expect(worstClips <= 0, "a frame computed \(worstClips) strip clips of panes that did not move")
        #expect(stale == 0, "\(stale) pane frames ended with a ring or clip off their host's frame")
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

    /// A divider drag in STRESS missed 49 frames (every-action sweep, macOS 27, cmux13s): each drag step
    /// re-placed every pane (a forced presentation pass on every reconcile). A drag step resizes the two
    /// panes beside the divider; every other pane's clip and ring stay as they are.
    @Test func aDividerDragStepTouchesOnlyThePanesBesideIt() async throws {
        let harness = PaneMotionBench.Harness(PaneMotionBench.grid(6, 5), focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        let transaction = LayoutTransactionID.make()
        var worstClips = 0, worstOverlay = 0
        for step in 1...20 {
            let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
            let before = Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), $0.frame) })
            let clips = screen.stripClipsComputed, overlay = harness.root.overlayHostsPlaced
            harness.model.setSplitRatio(SplitID("s0-0"), ratio: 0.2 + 0.005 * Double(step), transaction: transaction, phase: .changed)
            _ = await harness.frame()
            let moved = hosts.filter { before[ObjectIdentifier($0)] != $0.frame }.count
            worstClips = max(worstClips, screen.stripClipsComputed - clips - moved)
            worstOverlay = max(worstOverlay, harness.root.overlayHostsPlaced - overlay - moved)
        }
        #expect(worstClips <= 0, "a drag step computed \(worstClips) clips of panes that did not move")
        #expect(worstOverlay <= 0, "a drag step placed \(worstOverlay) rings of panes that did not move")
    }

    /// A strip pan (Command + scroll or a plain strip pan) moves every pane by the same offset: no pane's clip is
    /// recomputed (its inputs relative to the pane are the same), and the root reads as in layout motion for the
    /// whole gesture, so content that is costly to move per frame (divider catcher panels, page windows) waits
    /// for the landing (PL-scroll: 4-5 % missed frames at 120 Hz on cmux10s in both scroll modes).
    @Test func aStripPanFrameComputesNoClipAndReadsAsMotion() async throws {
        // 8 columns of half the window, 3 rows each: the strip overflows by 3 window widths.
        let columns = (0..<8).map { PaneMotionBench.column($0, rows: 3, width: 0.5) }
        let harness = PaneMotionBench.Harness([LayoutScreen(id: "s", name: "s", layout: .columns(columns))], focused: PaneID("p0-0"))
        _ = await harness.frame()
        let screen = try #require(harness.root.screenViews.values.first)
        #expect(screen.acceptsHorizontalScroll, "the strip does not overflow")
        screen.beginUserScroll()
        var worstClips = 0, notInMotion = 0
        for step in 1...30 {
            let clips = screen.stripClipsComputed
            screen.userScroll(deltaX: -12, timestamp: Double(step) / 120)
            _ = await harness.frame()
            worstClips = max(worstClips, screen.stripClipsComputed - clips)
            if !harness.root.isLayoutInMotion { notInMotion += 1 }
        }
        #expect(worstClips == 0, "a pan frame recomputed \(worstClips) clips of panes that only translate")
        #expect(notInMotion == 0, "\(notInMotion) pan frames did not read as layout motion")
        screen.endUserScroll(timestamp: 31.0 / 120)
        var frames = 0
        while await harness.frame().moving, frames < 240 { frames += 1 }
        #expect(!harness.root.isLayoutInMotion, "still in motion after the pan landed")
    }
}
