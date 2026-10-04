/// The terminal state of a remote session's readiness state machine.
///
/// A parked session has stopped every automatic recovery loop. Only an
/// explicit reconnect (or a system wake) resumes it, so nothing that waits on
/// readiness may keep waiting: every waiter is released with ``detail``, the
/// same actionable text the sidebar shows.
struct RemoteSessionParkedState: Equatable, Sendable {
    /// Which bounded supervisor gave up.
    enum Cause: String, Sendable {
        /// The daemon bootstrap kept failing the same way.
        case bootstrapFailed
        /// The SSH endpoint stayed unreachable.
        case hostUnreachable
        /// The daemon answered, but the relay or proxy never became ready.
        case readinessTimedOut
    }

    let cause: Cause
    /// App-localized, user-facing reason and next step.
    let detail: String
}
