/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Stop the process at the call (Debug with `CMUX_BLOCKING_TRAP=1`, and the detector's tests).
    case trap
    /// Record it once per call site and continue (bench-checks builds always, and Nightly to come; Debug by default
    /// until the sweep passes, lead decision 2026-10-24, flipped by p02-threads-021). In Debug each new site
    /// also logs one unified-log fault and shows as a badge in the Debug menu. A contended ``Mutex`` wait is
    /// always recorded, never a trap.
    case record
}

#if DEBUG || CMUX_BLOCKING_CHECKS
extension BlockingMode {
    /// The mode of a process started with `environment`: ``trap`` only in a Debug build started with
    /// `CMUX_BLOCKING_TRAP=1`, ``record`` in every other build (a bench, and to come a Nightly, never stops the
    /// app, whatever it was asked). A table reads it once, at its init; the violation path never reads the
    /// environment.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: The mode.
    static func resolved(environment: [String: String]) -> BlockingMode {
        #if DEBUG
        environment["CMUX_BLOCKING_TRAP"] == "1" ? .trap : .record
        #else
        .record
        #endif
    }
}
#endif
