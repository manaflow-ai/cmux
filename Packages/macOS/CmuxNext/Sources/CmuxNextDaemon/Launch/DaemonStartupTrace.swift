import Darwin
public import Foundation

/// The daemon's startup trace while the app's `CMUX_TRACE_STARTUP` records (p08-startup task 099): `server
/// ensure` hands it to the owner it spawns before the app's trace deadline, so only a cold launch's daemon gets
/// it (a running owner started before the trace, and a reconnect after the deadline gets nothing). The daemon
/// writes its startup marks as Chrome Trace Event JSON on `CLOCK_UPTIME_RAW` into `file` for the seconds left,
/// and `scripts/cmux-next/trace.py` puts that file beside the app's and Chromium's.
///
/// The names are the daemon's (`CMUX_TUI_*`, as ``DaemonDiagnosticKnobs`` passes the others): the app strips
/// every inherited `CMUX_*` variable at launch, and an app started from one of the daemon's shells reads only
/// its own `CMUX_TRACE_STARTUP`.
///
/// ```swift
/// let trace = DaemonStartupTrace(deadlineNanos: start + 5_000_000_000, file: URL(fileURLWithPath: "/tmp/startup-daemon.json"))
/// trace.environment(at: start + 1_500_000_000)
/// // ["CMUX_TUI_TRACE_STARTUP": "4", "CMUX_TUI_TRACE_STARTUP_FILE": "/tmp/startup-daemon.json"]
/// ```
public nonisolated struct DaemonStartupTrace: Sendable, Hashable {
    public static let secondsKey = "CMUX_TUI_TRACE_STARTUP"
    public static let fileKey = "CMUX_TUI_TRACE_STARTUP_FILE"

    /// `CLOCK_UPTIME_RAW` nanoseconds when the app's trace closes.
    public var deadlineNanos: UInt64
    /// The daemon's Chrome Trace Event JSON file.
    public var file: URL

    public init(deadlineNanos: UInt64, file: URL) {
        self.deadlineNanos = deadlineNanos
        self.file = file
    }

    /// The variables `server ensure` adds for the owner it spawns at `uptimeNanos` (`CLOCK_UPTIME_RAW`): the whole
    /// seconds left until the deadline, rounded up, and the file; none once the deadline passed.
    public func environment(at uptimeNanos: UInt64) -> [String: String] {
        guard deadlineNanos > uptimeNanos else { return [:] }
        let (whole, part) = (deadlineNanos - uptimeNanos).quotientAndRemainder(dividingBy: 1_000_000_000)
        let seconds = whole + (part > 0 ? 1 : 0)
        return [Self.secondsKey: String(seconds), Self.fileKey: file.path]
    }

    /// ``environment(at:)`` now.
    public var environment: [String: String] { environment(at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) }
}
