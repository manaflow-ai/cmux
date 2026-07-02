@testable import CmuxUpdater

@MainActor
final class RecordingUpdateActionDelegate: UpdateActionDelegate {
    private(set) var retryRequestCount = 0
    private(set) var retryPreserveInstallIntentValues: [Bool] = []
    private(set) var willRelaunchCount = 0

    /// Continuations awaiting the next retry request. Resumed the moment
    /// `updaterRequestsRetryCheckForUpdates` fires so tests wait on the actual event (causality)
    /// rather than a fixed number of scheduler yields (latency).
    private var retryWaiters: [CheckedContinuation<Void, Never>] = []

    func updaterRequestsRetryCheckForUpdates(preservingInstallIntent: Bool) {
        retryRequestCount += 1
        retryPreserveInstallIntentValues.append(preservingInstallIntent)
        let waiters = retryWaiters
        retryWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func updaterWillRelaunchApplication() {
        willRelaunchCount += 1
    }

    /// Suspend until at least `count` retry requests have been recorded. Resumes exactly when the
    /// retry action fires, so a test proceeds only once the retry has actually occurred — no
    /// scheduler-dependent fixed-duration wait. Both this type and the driver are `@MainActor`, so
    /// registering a waiter and resuming it are serialized and race-free.
    func waitForRetryRequests(atLeast count: Int) async {
        while retryRequestCount < count {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if retryRequestCount >= count {
                    continuation.resume()
                } else {
                    retryWaiters.append(continuation)
                }
            }
        }
    }
}
