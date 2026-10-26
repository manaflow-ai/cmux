import CmuxNextCompat

extension MainThreadWatchdog {
    /// Sets where the hang monitor's overdue registered threads go (the app's ``ThreadHangReporter``,
    /// which reports each one to crash reporting and the hang report). Nil (the default) drops them.
    public func attach(threadHangs reporter: ThreadHangReporter?) {
        threadHangSink.withLock { $0 = reporter }
    }

    /// One registered slot past its hang-watch deadline, from the hang monitor on this watchdog's
    /// thread (task 067 calls this once per overdue slot at each check, after it marked the slot
    /// block-on-capture). Watchdog thread only.
    ///
    /// - Returns: Whether a hang was reported (``ThreadHangReporter/capture(_:)``).
    @discardableResult
    public func captureThreadHang(_ overdue: ThreadHangReporter.Overdue) -> Bool {
        threadHangSink.withLock { $0 }?.capture(overdue) ?? false
    }
}
