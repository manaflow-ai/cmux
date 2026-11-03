import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
@testable import CmuxNextLayout
import CmuxNextTestSupport
import CmuxNextWakeups
import Darwin
import Foundation
import QuartzCore
import Testing

/// HOT PATH AUDIT frames (agent hpa-frames, 2026-11-03; handoff/hot-path-audit/frames/AUDIT.md): the work one display
/// frame costs on the frame-tick, motion-frame and cef-geometry paths, as deterministic counts (heap allocations on
/// the main thread through libmalloc's `malloc_logger` hook, presentation passes, overlay syncs, hosts resized and
/// laid out, page geometry evaluations). Time on a fleet worker without a 120 Hz display is noise; these counts are
/// not. Each case prints one `HPA-COUNT` line; the audit quotes them. The floor of each count is in its comment; the
/// fixes that close a gap add their own red test.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HotPathFrameCountTests {
    static let ticks = 256

    @MainActor final class StillLink: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    /// frame-tick (`FrameScheduler.deliver`, perf-hot 0.5 ms): one display frame delivered to 3 frame clients that do
    /// nothing. Floor: 0 allocations per tick in steady state.
    @Test func frameTickAllocations() throws {
        let link = StillLink()
        let scheduler = FrameScheduler.testing(makeLink: { _ in link })
        let clients = (0..<3).map { index in
            FrameClient(owner: "hpa.frame-tick.\(index)", isAnimation: true, on: scheduler) { _ in true }
        }
        for client in clients { client.activate() }
        defer { for client in clients { client.deactivate() } }
        var time: CFTimeInterval = 1000
        for _ in 0..<8 {
            time += 1.0 / 120
            scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 120)
        }
        let control = HotPathMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        let loop = try #require(HotPathMallocProbe.allocations {
            for _ in 0..<Self.ticks { time += 1.0 / 120 }
        })
        let measured = try #require(HotPathMallocProbe.allocations {
            for _ in 0..<Self.ticks {
                time += 1.0 / 120
                scheduler.frameDidFire(timestamp: time, refreshInterval: 1.0 / 120)
            }
        })
        let allocations = measured - loop
        print("HPA-COUNT case=frame-tick clients=3 ticks=\(Self.ticks) allocations=\(allocations) "
            + "per_tick=\(String(format: "%.2f", Double(allocations) / Double(Self.ticks))) loop=\(loop)")
        #expect(scheduler.frames > UInt64(Self.ticks))
    }

    /// motion-frame (`LayoutRootView.advanceFrame` -> `ScreenContentView.step` / `applyPresentation`, perf-hot 4 ms):
    /// the frames of one layout spring in a 4 x 3 grid (12 panes) with stub content, wired as the app wires the window
    /// (`LayoutWorkProbe`). Per frame: main-thread allocations, presentation passes, overlay syncs, ring hosts placed,
    /// hosts whose size changed (each one is a `layoutSubtreeIfNeeded` of that pane in the frame) and hosts that only
    /// moved. Floor: 1 presentation and at most 1 overlay sync per frame, work only for the panes whose rect changed,
    /// 0 allocations of our own per frame.
    @Test(arguments: ["close-row", "close-column", "ratio"])
    func motionFrameWork(_ change: String) async throws {
        let columns = (0..<4).map { PaneMotionBench.column($0, rows: 3, width: 0.25) }
        let probe = LayoutWorkProbe(.columns(columns), focused: PaneID("p0-0"))
        defer { probe.close() }
        var next = columns
        switch change {
        case "close-row": next[1] = PaneMotionBench.column(1, rows: 2, width: 0.25) // p1-2 closes: 2 panes grow
        case "close-column": next.removeFirst() // the strip shifts: 9 panes move, none resizes
        default: // every column's first split moves: 8 panes resize
            next = (0..<4).map { index in
                var column = PaneMotionBench.column(index, rows: 3, width: 0.25)
                if case let .split(id, axis, _, a, b) = column.root { column.root = .split(id, axis: axis, ratio: 0.2, a: a, b: b) }
                return column
            }
        }
        let control = HotPathMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        probe.model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .columns(next))])
        // The model's observation turn: the layout syncs and its springs start.
        for _ in 0..<4 { await Task.yield() }
        var lines: [String] = []
        var totals = (frames: 0, allocations: 0, presentations: 0, syncs: 0, placed: 0, resized: 0, moved: 0)
        var moving = true
        while moving, totals.frames < 240 {
            let screen = probe.screen
            let sizes = Dictionary(uniqueKeysWithValues: screen.subviews.compactMap { $0 as? PaneHostView }.map { (ObjectIdentifier($0), $0.frame) })
            let passes = screen.presentationPasses, syncs = probe.root.overlaySyncs, placed = probe.root.overlayHostsPlaced
            let started = CACurrentMediaTime()
            let allocations = HotPathMallocProbe.allocations { moving = probe.root.advanceFrame(1.0 / 120) } ?? -1
            let micros = Int((CACurrentMediaTime() - started) * 1_000_000)
            let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
            let resized = hosts.filter { host in sizes[ObjectIdentifier(host)].map { old in old.size != host.frame.size } ?? true }.count
            let moved = hosts.filter { host in
                sizes[ObjectIdentifier(host)].map { old in old.size == host.frame.size && old.origin != host.frame.origin } ?? false
            }.count
            let frame = (allocations, screen.presentationPasses - passes, probe.root.overlaySyncs - syncs,
                         probe.root.overlayHostsPlaced - placed, resized, moved)
            totals.frames += 1
            totals.allocations += frame.0
            totals.presentations += frame.1
            totals.syncs += frame.2
            totals.placed += frame.3
            totals.resized += frame.4
            totals.moved += frame.5
            if totals.frames <= 3 || !moving {
                lines.append("frame \(totals.frames): allocs=\(frame.0) presentations=\(frame.1) overlay_syncs=\(frame.2) "
                    + "rings_placed=\(frame.3) hosts_resized=\(frame.4) hosts_moved=\(frame.5) us=\(micros)")
            }
            probe.root.layoutSubtreeIfNeeded()
        }
        let n = Double(max(totals.frames, 1))
        func per(_ value: Int) -> String { String(format: "%.2f", Double(value) / n) }
        print("HPA-COUNT case=motion-frame change=\(change) panes=12 frames=\(totals.frames) "
            + "allocations=\(totals.allocations) per_frame_allocations=\(per(totals.allocations)) "
            + "per_frame_presentations=\(per(totals.presentations)) per_frame_overlay_syncs=\(per(totals.syncs)) "
            + "per_frame_rings_placed=\(per(totals.placed)) per_frame_hosts_resized=\(per(totals.resized)) "
            + "per_frame_hosts_moved=\(per(totals.moved))")
        for line in lines { print("HPA-COUNT   \(change) \(line)") }
        #expect(totals.frames > 1, "\(change): the change started no spring")
    }

    /// cef-geometry (`browserChildWindowPagesNeedUpdate` -> `CEFHostView.pagesNeedUpdate`, perf-hot 0.2 ms per post):
    /// one motion frame's page update request in a window with 8 Chromium hosts of which 1 moved, then the fork's
    /// reads of the moved page (occlusion rects and clip path). Per request: pages that worked out their geometry
    /// (posts + skips), posts, allocations; per fork read: occlusion and clip builds. Floor: 1 geometry evaluation
    /// and 1 post per moved page, 0 for the 7 still ones, and the fork's reads answered from that one evaluation.
    @Test func pageGeometryPerMotionFrame() throws {
        _ = NSApplication.shared
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        _ = WindowOverlayHost.host(for: window)
        defer {
            let panel = WindowOverlayHost.existingHost(for: window)?.panel
            window.closeAfterTest()
            panel?.close()
        }
        let stage = NSView(frame: content.bounds)
        content.addSubview(stage)
        let pages = (0..<8).map { index in
            CEFHostView(frame: CGRect(x: CGFloat(index % 4) * 400, y: CGFloat(index / 4) * 500, width: 400, height: 500))
        }
        for page in pages { stage.addSubview(page) }
        func forkReads(_ list: [CEFHostView]) {
            for page in list {
                _ = page.cmuxOcclusionRects()
                _ = page.cmuxClipPath()
            }
        }
        func request() {
            // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
            NotificationCenter.default.post(name: Notification.Name.browserChildWindowPagesNeedUpdate, object: window)
        }
        forkReads(pages)
        let control = HotPathMallocProbe.allocations { _ = ContiguousArray(repeating: 1, count: 64).count }
        try #require((control ?? 0) > 0, "malloc_logger saw no allocation on this thread: the probe cannot measure here")
        // A still frame: nothing moved.
        var stats = CEFHostView.trackerStats
        let stillAllocations = HotPathMallocProbe.allocations { request() } ?? -1
        let still = CEFHostView.trackerStats
        let stillEvaluated = (still.geometryPosts + still.geometrySkips) - (stats.geometryPosts + stats.geometrySkips)
        // A motion frame: the first page narrows.
        stats = CEFHostView.trackerStats
        pages[0].frame.size.width -= 8
        let movedAllocations = HotPathMallocProbe.allocations { request() } ?? -1
        let moved = CEFHostView.trackerStats
        let movedEvaluated = (moved.geometryPosts + moved.geometrySkips) - (stats.geometryPosts + stats.geometrySkips)
        let movedPosts = moved.geometryPosts - stats.geometryPosts
        // The fork's update of the moved page reads both.
        let readAllocations = HotPathMallocProbe.allocations { forkReads([pages[0]]) } ?? -1
        let read = CEFHostView.trackerStats
        print("HPA-COUNT case=cef-geometry pages=8 still_frame_evaluated=\(stillEvaluated) still_frame_allocations=\(stillAllocations) "
            + "moved_frame_evaluated=\(movedEvaluated) moved_frame_posts=\(movedPosts) moved_frame_allocations=\(movedAllocations) "
            + "fork_read_occlusion_builds=\(read.occlusionBuilds - moved.occlusionBuilds) fork_read_clip_builds=\(read.clipBuilds - moved.clipBuilds) "
            + "fork_read_allocations=\(readAllocations)")
        #expect(movedPosts == 1)
    }
}

// MARK: Counting the main thread's allocations

/// libmalloc's allocation hook type (`malloc_logger_t`): type flags, three arguments, the result, frames to skip.
private typealias HotPathMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

/// The hook's state: the C hook captures nothing, so it reads these.
nonisolated private struct HotPathMallocTally {
    /// The mach port of the thread being counted; 0 (`MACH_PORT_NULL`) while none is.
    static let thread = Atomic<UInt32>(0)
    /// Allocations that thread made since counting began.
    static let allocations = Atomic<Int>(0)
}

/// Counts the counted thread's allocations (and reallocations); allocates nothing itself.
nonisolated private func tallyHotPathMalloc(type: UInt32, arg1: UInt, arg2: UInt, arg3: UInt, result: UInt, skip: UInt32) {
    let allocate: UInt32 = 2  // MALLOC_LOG_TYPE_ALLOCATE
    guard type & allocate != 0, pthread_mach_thread_np(pthread_self()) == HotPathMallocTally.thread.load(ordering: .relaxed) else { return }
    _ = HotPathMallocTally.allocations.add(1, ordering: .relaxed)
}

/// How many heap allocations the calling thread makes in `body`, through libmalloc's `malloc_logger` hook
/// (as TipActionRunAllocationTests counts); nil when libmalloc exports no hook.
nonisolated private struct HotPathMallocProbe {
    static func allocations(_ body: () -> Void) -> Int? {
        // RTLD_DEFAULT, a C macro Swift does not import.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let hook = symbol.assumingMemoryBound(to: HotPathMallocLogger?.self)
        HotPathMallocTally.allocations.store(0, ordering: .relaxed)
        HotPathMallocTally.thread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
        let previous = hook.pointee
        hook.pointee = tallyHotPathMalloc
        body()
        hook.pointee = previous
        HotPathMallocTally.thread.store(0, ordering: .relaxed)
        return HotPathMallocTally.allocations.load(ordering: .relaxed)
    }
}
