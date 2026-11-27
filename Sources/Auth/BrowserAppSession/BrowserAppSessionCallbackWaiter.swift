import Foundation

@MainActor
private final class BrowserAppSessionCallbackWaiter {
    private var continuation:
        CheckedContinuation<BrowserAppSessionCallbackWaitOutcome, Never>?
    private var outcome: BrowserAppSessionCallbackWaitOutcome?
    private var timeoutTimer: DispatchSourceTimer?

    func wait(
        timeout: Duration,
        start: (@escaping @Sendable () -> Void) -> Void
    ) async -> BrowserAppSessionCallbackWaitOutcome {
        if let outcome {
            return outcome
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            start { [weak self] in
                Task { @MainActor in
                    self?.finish(.completed)
                }
            }

            let components = timeout.components
            let timeoutSeconds = max(
                0,
                TimeInterval(components.seconds)
                    + TimeInterval(components.attoseconds) / 1e18
            )
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler { [weak self] in
                Task { @MainActor in
                    self?.finish(.timedOut)
                }
            }
            timeoutTimer = timer
            timer.activate()
        }
    }

    func finish(_ resolved: BrowserAppSessionCallbackWaitOutcome) {
        guard outcome == nil else { return }
        outcome = resolved
        timeoutTimer?.cancel()
        timeoutTimer = nil
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: resolved)
    }
}

@MainActor
func awaitBrowserAppSessionCallback(
    timeout: Duration,
    start: (@escaping @Sendable () -> Void) -> Void
) async -> BrowserAppSessionCallbackWaitOutcome {
    let waiter = BrowserAppSessionCallbackWaiter()
    return await withTaskCancellationHandler {
        await waiter.wait(timeout: timeout, start: start)
    } onCancel: {
        Task { @MainActor in
            waiter.finish(.cancelled)
        }
    }
}
