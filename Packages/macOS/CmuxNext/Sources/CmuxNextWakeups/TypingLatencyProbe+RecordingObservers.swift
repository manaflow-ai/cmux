import CmuxNextCompat

extension TypingLatencyProbe {
    /// Calls `observe` with ``isRecording`` after each start and stop of key flows (``startFlows()``,
    /// ``stopFlows()``), on the thread that made it, as Chrome's `TraceLog::AddEnabledStateObserver` does for
    /// tracing (base/trace_event/trace_log.h). An observer stays for the probe's life.
    ///
    /// - Returns: false, and adds nothing, when the probe has its four observers already.
    @discardableResult
    public func observeRecording(_ observe: @escaping @Sendable (_ recording: Bool) -> Void) -> Bool {
        recordingObservers.add(observe)
    }
}
