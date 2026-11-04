import CmuxNextWakeups
import Foundation
import QuartzCore
import Testing

/// FRAME OWNER S1B 1b: `FrameScheduler.motionOrigin`, the time a motion that starts now starts from while the frames
/// tick, so a render-server move (a tab close) shows the same time of its curve in each frame as the frame clients.
@MainActor @Suite(.timeLimit(.minutes(1))) struct FrameSchedulerMotionOriginTests {
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

    static let refresh = 1.0 / 120

    /// No origin while nothing ticks; between ticks the time the last frame shows; in a tick the time the frame before
    /// it showed (where the clients' steps start); none again once the clients went idle.
    @Test func theOriginIsWhereTheFrameClientsStepFrom() {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        #expect(scheduler.motionOrigin == nil, "an idle scheduler has an origin")
        var inTick: [CFTimeInterval?] = [], steps: [Double] = [], targets: [CFTimeInterval] = []
        let client = FrameClient(owner: "spring", on: scheduler) { tick in
            inTick.append(scheduler.motionOrigin)
            steps.append(tick.frameElapsed)
            targets.append(tick.targetTimestamp)
            return true
        }
        client.activate()
        #expect(scheduler.motionOrigin == nil, "an origin before the first frame")
        for _ in 0..<3 {
            scheduler.frameDidFire(timestamp: media.now, refreshInterval: Self.refresh)
            #expect(scheduler.motionOrigin == media.now + Self.refresh, "between ticks the origin is the last frame's target")
            media.now += Self.refresh
        }
        for (index, origin) in inTick.enumerated() {
            #expect(origin.map { abs($0 - (targets[index] - steps[index])) < 1e-9 } == true,
                    "tick \(index): the origin \(String(describing: origin)) is not where the clients step from (\(targets[index] - steps[index]))")
        }
        client.deactivate()
        #expect(scheduler.motionOrigin == nil, "an origin after the clients went idle")
    }

    /// At most one catch-up step back (a late event turn) and at most one refresh ahead of now.
    @Test func theOriginIsBoundedAroundNow() {
        let media = Media()
        let scheduler = FrameScheduler.testing(mediaTime: media.read) { _ in Link() }
        let client = FrameClient(owner: "spring", on: scheduler) { _ in true }
        client.activate()
        defer { client.deactivate() }
        scheduler.frameDidFire(timestamp: media.now, refreshInterval: Self.refresh)
        media.now += 1
        #expect(scheduler.motionOrigin.map { abs($0 - (media.now - FrameScheduler.catchUpLimit)) < 1e-9 } == true,
                "a stale origin is not bounded to one catch-up step: \(String(describing: scheduler.motionOrigin))")
        media.now -= 1 + Self.refresh / 2
        #expect(scheduler.motionOrigin.map { $0 <= media.now + Self.refresh + 1e-9 } == true,
                "the origin is more than one refresh ahead of now: \(String(describing: scheduler.motionOrigin))")
    }
}
