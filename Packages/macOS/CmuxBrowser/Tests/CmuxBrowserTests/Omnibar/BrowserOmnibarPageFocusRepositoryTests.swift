import Testing
import Foundation
@testable import CmuxBrowser

/// Records scripts and replays a queued sequence of evaluation outcomes.
@MainActor
private final class FakeScriptEvaluator: BrowserOmnibarScriptEvaluating {
    var evaluatedScripts: [String] = []
    /// Each pending tuple is delivered to the next evaluation, in order.
    var queuedResults: [(Any?, (any Error)?)] = []
    private var index = 0

    func evaluateOmnibarPageFocusScript(
        _ script: String,
        completion: @escaping @MainActor (Any?, (any Error)?) -> Void
    ) {
        evaluatedScripts.append(script)
        let outcome: (Any?, (any Error)?)
        if index < queuedResults.count {
            outcome = queuedResults[index]
            index += 1
        } else {
            outcome = (nil, nil)
        }
        completion(outcome.0, outcome.1)
    }
}

private struct StubError: Error {}

@MainActor
@Suite struct BrowserOmnibarPageFocusRepositoryTests {
    @Test func captureRunsCaptureScript() {
        let evaluator = FakeScriptEvaluator()
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        repo.captureIfNeeded(panelDebugID: "abcde")
        #expect(evaluator.evaluatedScripts.count == 1)
        #expect(evaluator.evaluatedScripts[0] == BrowserOmnibarPageFocusRepository.captureScript)
    }

    @Test func restoreSucceedsOnFirstAttempt() {
        let evaluator = FakeScriptEvaluator()
        evaluator.queuedResults = [("restored", nil)]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        #expect(outcome == true)
        #expect(evaluator.evaluatedScripts == [BrowserOmnibarPageFocusRepository.restoreScript])
    }

    @Test func restoreStopsOnNoStateWithoutRetry() {
        let evaluator = FakeScriptEvaluator()
        evaluator.queuedResults = [("no_state", nil)]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        // no_state is terminal: it is not in the retry set, so exactly one eval.
        #expect(outcome == false)
        #expect(evaluator.evaluatedScripts.count == 1)
    }

    @Test func restoreStopsOnMissingTargetWithoutRetry() {
        let evaluator = FakeScriptEvaluator()
        evaluator.queuedResults = [("missing_target", nil)]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        #expect(outcome == false)
        #expect(evaluator.evaluatedScripts.count == 1)
    }

    @Test func restoreRetriesSynchronousZeroDelayAttempts() {
        // The first retry delay is 0.0s, which asyncAfter schedules on the main
        // queue rather than running inline, so the synchronous portion stops at
        // the first not_focused result. Verify the first attempt happened and
        // the completion has not yet fired (it is pending on the run loop).
        let evaluator = FakeScriptEvaluator()
        evaluator.queuedResults = [("not_focused", nil)]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        #expect(evaluator.evaluatedScripts.count == 1)
        #expect(outcome == nil)
    }

    @Test func invalidateAbortsPendingRetry() async {
        let evaluator = FakeScriptEvaluator()
        evaluator.queuedResults = [("not_focused", nil)]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        // Bump generation before the scheduled 0.0s retry runs.
        repo.invalidateRestoreAttempts(panelDebugID: "abcde")
        // Drain the main queue until the scheduled asyncAfter block fires its
        // completion. The stale-generation guard inside that block reports
        // false, so `outcome` becoming non-nil is the real completion signal;
        // wait on it rather than on wall-clock time.
        await Self.drainUntil(deadlineSeconds: 2.0) { outcome != nil }
        #expect(outcome == false)
        // Only the initial attempt ran; the stale retry was dropped.
        #expect(evaluator.evaluatedScripts.count == 1)
    }

    /// Pumps the main run loop until `predicate` holds, returning the instant it
    /// does. The scheduled retry runs as a `DispatchQueue.main.asyncAfter` work
    /// item, so yielding lets the main queue drain it; this resolves as soon as
    /// the completion fires and only fails at the generous deadline.
    private static func drainUntil(
        deadlineSeconds: Double,
        _ predicate: @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(deadlineSeconds)
        while !predicate() {
            if Date() >= deadline { break }
            await Task.yield()
        }
    }

    @Test func restoreReportsFalseOnEvaluationError() {
        let evaluator = FakeScriptEvaluator()
        // error is retryable; with the full 4-slot schedule the last attempt
        // still completes false once all delays are exhausted. The synchronous
        // path runs only the first attempt (delay 0.0 reschedules).
        evaluator.queuedResults = [(nil, StubError())]
        let repo = BrowserOmnibarPageFocusRepository(evaluator: evaluator)
        var outcome: Bool?
        repo.restoreIfNeeded(panelDebugID: "abcde") { outcome = $0 }
        #expect(evaluator.evaluatedScripts.count == 1)
        #expect(outcome == nil)
    }

    @Test func statusMapping() {
        #expect(AddressBarPageFocusRestoreStatus.from(result: "restored", error: nil) == .restored)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "no_state", error: nil) == .noState)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "missing_target", error: nil) == .missingTarget)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "not_focused", error: nil) == .notFocused)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "error", error: nil) == .error)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "garbage", error: nil) == .error)
        #expect(AddressBarPageFocusRestoreStatus.from(result: 42, error: nil) == .error)
        #expect(AddressBarPageFocusRestoreStatus.from(result: "restored", error: StubError()) == .error)
    }
}
