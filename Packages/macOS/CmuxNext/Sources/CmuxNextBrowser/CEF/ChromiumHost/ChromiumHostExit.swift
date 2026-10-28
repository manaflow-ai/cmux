#if DEBUG || CMUX_BENCH_HOOKS
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import Darwin

/// How a Chromium host process ended.
nonisolated struct ChromiumHostExit: Equatable, Sendable, CustomStringConvertible {
    /// The signal that ended it (SIGKILL, SIGSEGV, SIGTRAP for a CHECK), or nil for an exit.
    var signal: Int32?
    /// The exit status when it exited.
    var status: Int32?

    var description: String {
        if let signal { return "signal \(signal)" }
        return "exit \(status ?? -1)"
    }

    /// The exit statuses of a host that could not start (`kExit*` in
    /// `ChromiumHost/src/chromium_host_wire.h`), with what each means.
    static let startFailures: [Int32: String] = [
        64: "launched without the wire",
        65: "the Chromium framework did not load",
        66: "the Chromium fork is older than the host needs",
        67: "CefInitialize failed",
    ]

    /// Why the host could not start, when it exited with one of
    /// ``startFailures``; nil for a crash, a signal or any other exit. A new
    /// host would fail the same way, so the session does not restart it.
    var startFailure: String? {
        guard signal == nil, let status, let reason = Self.startFailures[status] else { return nil }
        return "could not start (exit \(status)): \(reason)"
    }

    /// The crash state every page of this host shows when it ends (``ChromiumHostExitReporting``);
    /// nil for a clean exit (status 0: quit or the idle exit), which shows nothing.
    /// Signals follow Chrome's `GetTerminationStatus` (base/process/kill_posix.cc): a fault or a
    /// CHECK's trap is a crash; SIGKILL, SIGINT and SIGTERM mean something outside ended it. A start
    /// failure (``startFailures``) is a launch failure; any other end is abnormal, so a host never
    /// leaves its pages blank. `code` is in `waitpid` form, as the sad tab reads it
    /// (``BrowserProcessExit/codeDescription``), and its process is the host.
    var pageExit: BrowserProcessExit? {
        if let signal {
            let reason: BrowserProcessExit.Reason = switch signal {
            case SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS: .crashed
            case SIGKILL, SIGINT, SIGTERM: .killed
            default: .abnormal
            }
            return BrowserProcessExit(reason: reason, code: Int(signal), engine: .cef, process: .chromiumHost)
        }
        // Ended, its status unreadable.
        guard let status else { return BrowserProcessExit(reason: .abnormal, engine: .cef, process: .chromiumHost) }
        guard status != 0 else { return nil }
        let reason: BrowserProcessExit.Reason = startFailure == nil ? .abnormal : .launchFailed
        return BrowserProcessExit(reason: reason, code: Int(status) << 8, engine: .cef, process: .chromiumHost)
    }
}
#endif
