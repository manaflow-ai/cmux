@testable import CmuxNextApp
import CmuxNextControl
import Foundation
import Testing

/// A model change soon after the last control snapshot publish waits for its delay (100 ms)
/// with no frames (idle-wakeups.md: nothing polls). Before, the publisher asked for a display
/// frame on every frame until the delay passed: about 12 main-thread wakeups at 120 Hz for each
/// model change, on an otherwise idle app.
@MainActor @Suite struct ControlPublishPacerTests {
    /// Frames asked for, run by hand.
    final class Frames: ControlFrameSource, @unchecked Sendable {
        // Only the main actor (the test) touches it.
        var pending: [@MainActor @Sendable () -> Void] = []
        var asked = 0
        func scheduleFrame(_ work: @escaping @MainActor @Sendable () -> Void) {
            asked += 1
            pending.append(work)
        }

        @MainActor func runFrame() {
            let works = pending
            pending = []
            for work in works { work() }
        }
    }

    @Test func aDelayedPublishAsksForNoFrameUntilItsDelayPasses() async throws {
        let frames = Frames()
        let clock = ManualClock()
        let pacer = ControlPublishPacer(frames: frames, clock: clock)
        var publishes = 0
        pacer.publish = { publishes += 1 }
        pacer.request(after: .milliseconds(100))
        for _ in 0..<12 { frames.runFrame() }
        #expect(frames.asked == 0, "\(frames.asked) frames asked for while the delay runs")
        #expect(publishes == 0)
        try await clock.waitForSleeper()
        clock.advance(by: .milliseconds(100))
        for _ in 0..<200 where frames.asked == 0 { await Task.yield() }
        #expect(frames.asked == 1, "the delay's end asks for one frame")
        frames.runFrame()
        #expect(publishes == 1)
    }

    @Test func aFrameRequestOvertakesAPendingDelay() {
        let frames = Frames()
        let pacer = ControlPublishPacer(frames: frames, clock: ManualClock())
        var publishes = 0
        pacer.publish = { publishes += 1 }
        pacer.request(after: .milliseconds(100))
        pacer.requestFrame()
        pacer.requestFrame()
        frames.runFrame()
        #expect(publishes == 1)
        #expect(frames.asked == 1)
        frames.runFrame()
        #expect(publishes == 1, "nothing is left pending")
    }
}
