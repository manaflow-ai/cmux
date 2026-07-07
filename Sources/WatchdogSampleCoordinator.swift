/// Serializes watchdog sampling so a burst of socket commands stalled behind the
/// same main-actor hang spawns a single `/usr/bin/sample` instead of one per
/// command. The in-flight sample already captures the shared stall, so later
/// watchdogs coalesce onto it rather than piling more sampler processes, disk
/// writes, and log work onto an already-unhealthy app. Owned and constructed by
/// the `SocketCommandObservability` instance, not shared ambient state.
actor WatchdogSampleCoordinator {
    private var isCapturing = false

    /// Claims the single capture slot. Returns `true` when the caller may capture
    /// (and must then call ``endCapture()`` exactly once), or `false` when a
    /// capture is already in flight and this watchdog should coalesce onto it.
    func beginCaptureIfIdle() -> Bool {
        guard !isCapturing else { return false }
        isCapturing = true
        return true
    }

    func endCapture() {
        isCapturing = false
    }
}
