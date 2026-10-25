/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Hand the call to the sink (waiting at most 50 ms), log one fault, then stop the process at the call:
    /// a checked build launched with `CMUX_BLOCKING_TRAP=1` (Debug, and bench or Nightly as an opt-in crash
    /// mode), and the detector's tests.
    case trap
    /// Record it once per call site and continue: every checked build by default (Debug until the known
    /// violations are fixed, lead decision 2026-10-24; bench; Nightly). A contended ``Mutex`` wait is always
    /// recorded, never a trap.
    case record
}

#if DEBUG || CMUX_BLOCKING_CHECKS
extension BlockingMode {
    /// The launch environment variable that asks for ``trap``.
    static let trapVariable = "CMUX_BLOCKING_TRAP"

    /// The mode a launch asked for: ``trap`` when `CMUX_BLOCKING_TRAP=1`, otherwise ``record``. The table
    /// reads it once, at init. This is Chrome's configurable DCHECK (base/check.h `DCHECK_IS_CONFIGURABLE`):
    /// a Canary ships its DCHECKs on but non-fatal, and a launch can make them fatal.
    ///
    /// - Parameter environment: The process environment.
    init(environment: [String: String]) {
        self = environment[Self.trapVariable] == "1" ? .trap : .record
    }
}
#endif
