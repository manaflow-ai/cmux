import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// The first frame of an animation that starts from rest advances one display refresh, not two
/// (RESIZE VIDEOS, Lawrence 2026-11-02: "make sure all animations are world class and 120hz").
/// An idle window has no display link; the first tick after it starts had no previous timestamp and
/// stepped every client by 1/60 s. At 120 Hz that put the first moving frame of every split, close,
/// New Column, zoom, equalize and screen switch two refreshes along its spring, then the motion went
/// on at one refresh per frame: a lurch at the start, off the declared curve. The first tick now
/// steps by the display's own refresh period, which the link reports with every frame.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerFirstTickTests {
    @MainActor
    private final class Link: FrameLink {
        var isPaused = false
        func invalidate() {}
    }

    @MainActor
    private final class Media {
        var now: CFTimeInterval = 500
        var read: @MainActor () -> CFTimeInterval { { [self] in self.now } }
    }

    /// Ticks one client through `frames` display frames of `interval` and returns each tick's elapsed time.
    private static func elapsed(frames: Int, interval: Double, on scheduler: FrameScheduler, media: Media) -> [Double] {
        var seen: [Double] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in
            seen.append(tick.elapsed)
            return true
        }
        client.activate()
        for _ in 0..<frames {
            media.now += interval
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: interval)
        }
        client.deactivate()
        return seen
    }

    @Test(arguments: [1.0 / 120, 1.0 / 60, 1.0 / 90])
    func theFirstFrameFromRestStepsOneRefresh(interval: Double) {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        let first = Self.elapsed(frames: 4, interval: interval, on: scheduler, media: media)
        #expect(first.count == 4)
        #expect(first.allSatisfy { abs($0 - interval) < 1e-9 }, "every tick, the first included, is one refresh (\(interval)): \(first)")
        // Idle (the link is dropped), then a new animation: its first frame is one refresh again.
        media.now += 2
        let again = Self.elapsed(frames: 3, interval: interval, on: scheduler, media: media)
        #expect(again.allSatisfy { abs($0 - interval) < 1e-9 }, "after an idle period too: \(again)")
    }

    /// A synthesized frame (no display link: a stall or a headless launch) has no refresh period: it keeps 1/60.
    @Test func aFirstFrameWithoutARefreshPeriodKeepsTheFallback() {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        var seen: [Double] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in
            seen.append(tick.elapsed)
            return true
        }
        client.activate()
        media.now += 0.01
        scheduler.frameDidFire(timestamp: media.now, refreshInterval: nil)
        client.deactivate()
        #expect(seen.count == 1)
        #expect(abs((seen.first ?? 0) - 1.0 / 60) < 1e-9, "fallback 1/60: \(seen)")
    }
}
