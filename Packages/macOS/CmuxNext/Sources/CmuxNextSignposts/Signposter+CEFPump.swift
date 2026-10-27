import CmuxNextTrace
import os

// The `cef.pump` interval with its numbers: one `OSSignposter` interval (Instruments, `log stream --signpost`) per
// Chromium message pump pass, and one trace ring thread slice (B/E) per pass while a recording runs. Like Chrome's
// `ThreadControllerWithMessagePumpImpl::DoWork` slice around each batch of work
// (base/task/sequence_manager/thread_controller_with_message_pump_impl.cc), which is in a category only a trace
// session turns on. Not mirrored to MetricKit (``SignpostMetricKitMirror/mirrors(_:)``). The fields are formatted by
// the log system only when something reads them, so a pass builds no `String`.
extension Signposter {
    /// The recording-only category a ring slice of ``SignpostName/cefPump`` also needs on: passes run up to 100
    /// times a second while a page loads, which would crowd the black box's action, key and switch records out.
    /// `task` is the per-turn work category (like the holder's `task.holder_poll`), off in the black box.
    static let cefPumpRecordingCategory = SignpostCategory.task

    /// Begins a ``SignpostName/cefPump`` pass (`reason=<code>`). The ring's B, written only while both `cef` and
    /// ``cefPumpRecordingCategory`` are on, holds `reasonCode` in `arg0`. End it on this thread with
    /// ``endCEFPump(_:longRun:elapsedMicros:)``.
    ///
    /// - Parameter reasonCode: Why the pass runs: the armed timer fire's reason code, 0 for a pass no timer armed.
    /// - Returns: The state to pass to ``endCEFPump(_:longRun:elapsedMicros:)``.
    public func beginCEFPump(reasonCode: UInt64) -> SignpostInterval {
        openInterval(.cefPump, arg0: reasonCode, traced: trace.isEnabled(categoryBit: Self.cefPumpRecordingCategory.traceBit)) {
            signposter.beginInterval(SignpostName.cefPump.staticName, id: $0, "reason=\(reasonCode, privacy: .public)")
        }
    }

    /// Ends a ``SignpostName/cefPump`` pass begun with ``beginCEFPump(reasonCode:)``: the log system's end carries
    /// `long=<0|1> elapsed_us=<us>`, and the ring's E holds 1 for a long run in `arg0` and the elapsed time in us in
    /// `arg1`. The E is written exactly when the B was, whatever the category flags are now.
    ///
    /// - Parameters:
    ///   - interval: The state ``beginCEFPump(reasonCode:)`` returned.
    ///   - longRun: The pass used CEF's whole time slice.
    ///   - elapsedMicros: The pass's main-thread time in microseconds.
    public func endCEFPump(_ interval: SignpostInterval, longRun: Bool, elapsedMicros: UInt64) {
        let name = SignpostName.cefPump
        let long: UInt64 = longRun ? 1 : 0
        signposter.endInterval(name.staticName, interval.state,
                               "long=\(long, privacy: .public) elapsed_us=\(elapsedMicros, privacy: .public)")
        if let id = interval.metricKitID { mirror.end(name, id: id) }
        closeInterval(name, interval, arg0: long, arg1: elapsedMicros)
    }
}
