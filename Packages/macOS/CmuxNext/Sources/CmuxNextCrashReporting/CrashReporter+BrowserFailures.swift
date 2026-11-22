import Sentry

extension CrashReporter {
    /// Sends a browser failure (``BrowserFailureEvent``). Does nothing when crash reporting is off.
    /// - Parameter failure: The failure and its count.
    public nonisolated func reportBrowserFailure(_ failure: BrowserFailureEvent) {
        guard isStarted else { return }
        SentrySDK.capture(event: failure.event())
    }
}
