import CmuxNextWakeups
import QuartzCore
@testable import CmuxNextTerminal
import Testing

/// A new terminal tab's `create.tab` end (p09-observability task 030, ``TerminalFirstFrameWatch``): the watch reads
/// the surface at each display frame only while it waits, runs `shown` once at the first frame, `closed` once when
/// the surface went away first, and neither after ``TerminalFirstFrameWatch/cancel()`` (a tab hidden first), which
/// takes its frame client off the scheduler. The surface is a fake state the test sets; frames are fired by hand on
/// a test scheduler.
@MainActor @Suite(.serialized)
struct TerminalFirstFrameWatchTests {
    @MainActor final class Surface {
        var state: TerminalFirstFrameWatch.SurfaceState = .waiting
        private(set) var reads = 0
        private(set) var shown = 0
        private(set) var closed = 0

        func watch(on scheduler: FrameScheduler) -> TerminalFirstFrameWatch {
            TerminalFirstFrameWatch(scheduler: { scheduler }, read: { [self] in
                reads += 1
                return state
            }, shown: { [self] in shown += 1 }, closed: { [self] in closed += 1 })
        }
    }

    final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    private func scheduler() -> FrameScheduler {
        FrameScheduler.testing(mediaTime: { CACurrentMediaTime() }) { _ in Link() }
    }

    private func frame(_ scheduler: FrameScheduler) {
        scheduler.frameDidFire(timestamp: CACurrentMediaTime(), refreshInterval: 1.0 / 60)
    }

    @Test func aSurfaceThatHasAFrameShowsAtOnceAndNeverTicks() {
        let scheduler = scheduler()
        let surface = Surface()
        surface.state = .framed
        let watch = surface.watch(on: scheduler)
        #expect(surface.shown == 1)
        #expect(!watch.isWaiting)
        #expect(!watch.isTicking)
    }

    @Test func theFirstFrameRunsShownOnceAndTheClientGoesIdle() {
        let scheduler = scheduler()
        let surface = Surface()
        let watch = surface.watch(on: scheduler)
        #expect(watch.isTicking)
        frame(scheduler)
        #expect(surface.shown == 0)
        surface.state = .framed
        frame(scheduler)
        #expect(surface.shown == 1)
        #expect(!watch.isTicking)
        let reads = surface.reads
        frame(scheduler)
        #expect(surface.reads == reads, "no read after the wait is over")
        surface.state = .gone
        frame(scheduler)
        #expect((surface.shown, surface.closed) == (1, 0))
    }

    @Test func aSurfaceRemovedFromItsViewRunsClosedOnce() {
        let scheduler = scheduler()
        let surface = Surface()
        let watch = surface.watch(on: scheduler)
        surface.state = .gone
        frame(scheduler)
        surface.state = .framed
        frame(scheduler)
        #expect((surface.shown, surface.closed) == (0, 1))
        #expect(!watch.isWaiting)
        #expect(!watch.isTicking)
    }

    /// A tab hidden before its first frame: a hidden terminal's rendering is suspended, so the watch must not keep
    /// reading its layer every frame.
    @Test func cancelRunsNeitherAndStopsTheFrameClient() {
        let scheduler = scheduler()
        let surface = Surface()
        let watch = surface.watch(on: scheduler)
        watch.cancel()
        #expect(!watch.isTicking)
        let reads = surface.reads
        surface.state = .framed
        frame(scheduler)
        #expect(surface.reads == reads)
        #expect((surface.shown, surface.closed) == (0, 0))
    }
}
