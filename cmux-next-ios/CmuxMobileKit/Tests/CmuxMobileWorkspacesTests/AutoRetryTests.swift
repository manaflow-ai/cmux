import CmuxMobileDesign
import Foundation
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1))) struct AutoRetryTests {
    @Test func backoffDoublesUpToTheCapAndStaysInItsUpperHalf() {
        let backoff = AutoRetryBackoff.standard
        #expect(backoff.delay(beforeRetry: 0, unit: 1) == .seconds(1))
        #expect(backoff.delay(beforeRetry: 0, unit: 0) == .milliseconds(500))
        #expect(backoff.delay(beforeRetry: 3, unit: 1) == .seconds(8))
        #expect(backoff.delay(beforeRetry: 10, unit: 1) == .seconds(30))
        #expect(backoff.delay(beforeRetry: 1_000, unit: 0) == .seconds(15))
        for n in 0..<12 {
            let full = min(Duration.seconds(30), .seconds(1) * (1 << n))
            let drawn = backoff.delay(beforeRetry: n, unit: Double.random(in: 0...1))
            #expect(drawn >= full / 2 && drawn <= full)
        }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func fast(quiet: Duration = .seconds(30)) -> AutoRetry {
        AutoRetry(backoff: AutoRetryBackoff(first: .milliseconds(5), cap: .milliseconds(20)), quiet: quiet, draw: { 1 })
    }

    @Test func aFailureRetriesOnItsOwnUntilTheLoadSucceeds() async {
        let retry = fast()
        var calls = 0
        retry.setAttempt {
            calls += 1
            // Loading, then the answer: the third attempt succeeds.
            retry.update(failing: false)
            retry.update(failing: calls < 3)
        }
        retry.update(failing: true)
        #expect(await until { calls == 3 && retry.attempts == 0 })
        try? await Task.sleep(for: .milliseconds(60))
        #expect(calls == 3, "no retry after success")
        #expect(!retry.isQuietLineShown)
    }

    @Test func nothingShowsBeforeTheQuietBoundThenOneLine() async {
        let retry = fast(quiet: .milliseconds(80))
        retry.setAttempt {
            retry.update(failing: false)
            retry.update(failing: true)
        }
        retry.update(failing: true)
        #expect(!retry.isQuietLineShown)
        // The loading phases between attempts do not restart the bound.
        #expect(await until { retry.isQuietLineShown })
        retry.setAttempt { retry.update(failing: false) }
        #expect(await until { !retry.isQuietLineShown })
    }

    @Test func backgroundStopsRetriesAndForegroundRetriesAtOnce() async {
        let retry = AutoRetry(backoff: AutoRetryBackoff(first: .seconds(60), cap: .seconds(60)), draw: { 1 })
        var calls = 0
        retry.setAttempt { calls += 1 }
        retry.update(foreground: false)
        retry.update(failing: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(calls == 0)
        retry.update(foreground: true)
        #expect(await until { calls == 1 }, "one attempt right away on return to the foreground")
        // Let that attempt finish: a return while one is in flight starts none of its own.
        #expect(await until { retry.attempts == 1 && !retry.isAttemptInFlight })
        retry.update(visible: false)
        retry.update(visible: true)
        #expect(await until { calls == 2 }, "and on the screen appearing again")
    }

    @Test func leavingScreenCancelsAttemptAndReturningRetriesImmediately() async {
        let retry = fast()
        var calls = 0
        retry.setAttempt {
            calls += 1
            try? await Task.sleep(for: .seconds(60))
        }
        retry.update(failing: true)
        #expect(await until { retry.isAttemptInFlight })

        retry.update(visible: false)
        #expect(!retry.isAttemptInFlight)
        retry.update(visible: true)
        #expect(await until { calls == 2 }, "the return starts a fresh attempt")
        retry.update(failing: false)
    }
}
