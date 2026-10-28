extension CEFMessagePump {
    /// Why a timer fire woke the main thread (`debug.wakeups` reason).
    nonisolated enum LedgerReason: String, CaseIterable, Sendable {
        /// An immediate request: `OnScheduleMessagePumpWork(0)` or cmux's own "pump now".
        case now
        /// The fire date of CEF's delayed request.
        case delayed
        /// The deadline of a Chromium thread's delayed request the gate kept (``CEFPumpCrossThreadGate``).
        case kept
        /// A fire while a pass was running (a nested run loop); the outer pass runs the pump again.
        case reentered

        /// The reason's number in a `cef.pump` begin record (`arg0`): fixed and nonzero, so 0 is a pass no timer
        /// armed (the quit path's drain). A reentered fire runs no pass; 4 marks the pass that runs it after the
        /// outer pass returns.
        var traceCode: UInt64 {
            switch self {
            case .now: 1
            case .delayed: 2
            case .kept: 3
            case .reentered: 4
            }
        }
    }
}
