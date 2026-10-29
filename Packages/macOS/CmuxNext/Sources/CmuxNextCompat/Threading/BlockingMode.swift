/// What the detector does with a main-thread blocking call.
public enum BlockingMode: String, Sendable {
    /// Hand the call to the sink (waiting at most 50 ms), log one fault, then stop the process at the call:
    /// a Debug or Nightly build launched with `CMUX_BLOCKING_TRAP=1` (the opt-in crash mode), and the
    /// detector's tests. A bench build never traps.
    case trap
    /// Record it once per call site and continue: every checked build by default (Debug until the sweep passes,
    /// lead decision 2026-10-24, flipped by p02-threads-021; Nightly, which logs each site with ``BlockingLogSink``),
    /// and a bench-checks build always. In Debug each new site also logs one unified-log fault and shows as a badge
    /// in the Debug menu. A contended ``Mutex`` wait is always recorded, never a trap.
    case record
}

#if DEBUG || CMUX_BLOCKING_CHECKS
extension BlockingMode {
    /// The launch environment variable that asks for ``trap``.
    static let trapVariable = "CMUX_BLOCKING_TRAP"

    /// The mode of a process started with `environment`: ``trap`` when `CMUX_BLOCKING_TRAP=1` (a Debug or a
    /// Nightly build), otherwise ``record``. A bench build (`CMUX_BENCH_HOOKS`) is always ``record``: a bench run
    /// measures the app, and a shell that exports the variable for Debug work passes it to the bench app too. A
    /// table reads it once, at its init; the violation path never reads the environment. This is Chrome's
    /// configurable DCHECK (base/check.h `DCHECK_IS_CONFIGURABLE`): a Canary ships its DCHECKs on but non-fatal,
    /// and a launch can make them fatal.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: The mode.
    static func resolved(environment: [String: String]) -> BlockingMode {
        #if CMUX_BENCH_HOOKS
        .record
        #else
        environment[trapVariable] == "1" ? .trap : .record
        #endif
    }
}
#endif
