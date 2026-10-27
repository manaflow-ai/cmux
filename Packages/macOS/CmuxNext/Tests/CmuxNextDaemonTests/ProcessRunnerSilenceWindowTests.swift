import CmuxNextWakeups
import CmuxNextWakeupsTestSupport
import Testing
@testable import CmuxNextDaemon

/// `ProcessRunner.run(progressIdle:)` kills a child whose stdout stays silent for `progressIdle`. The silence
/// deadline is one-shot and moved lazily, as Chromium's `DelayTimerBase` re-posts for the time left to its
/// desired run time (base/timer/timer.cc): a fire that finds a later write sleeps on until that write plus
/// `progressIdle`. Before, each fire that saw a write slept a whole new window, so a child that wrote once just
/// after a window began and then went silent was killed up to about two windows after its last output.
struct ProcessRunnerSilenceWindowTests {
    @Test(.timeLimit(.minutes(1)))
    func oneWriteThenSilenceEndsOneIdleWindowAfterTheWrite() async throws {
        let clock = ManualClock()
        let progress = StdoutProgress(elapsed: { clock.now.offset })
        let silence = Task {
            try await ProcessRunner.waitForSilence(of: progress, idle: .seconds(1), cap: .seconds(60), clock: clock)
        }
        try await clock.waitForSleeper()
        #expect(clock.sleepRequests.last?.deadline == ManualClock.Instant(offset: .seconds(1)), "the first silence deadline")

        clock.advance(by: .milliseconds(100))
        progress.noteWrite()
        clock.advance(by: .milliseconds(900))
        try await clock.waitForSleeper()
        let resleep = clock.sleepRequests.last
        #expect(resleep?.deadline == ManualClock.Instant(offset: .milliseconds(1_100)),
                "the fire at 1 s saw the write at 0.1 s and sleeps to 1.1 s, not a new window: \(String(describing: resleep))")
        #expect(resleep?.tolerance == WakeLeeway.window(delay: .milliseconds(100)).tolerance, "the leeway of the time left")

        clock.advance(by: .milliseconds(100))
        let ended = await Deadline(.seconds(5)).value("ProcessRunnerSilenceWindowTests") { () async -> Bool in
            (try? await silence.value) != nil
        }
        silence.cancel()
        #expect(ended == true, "no write since 0.1 s: the silence ends at 1.1 s")
    }
}
