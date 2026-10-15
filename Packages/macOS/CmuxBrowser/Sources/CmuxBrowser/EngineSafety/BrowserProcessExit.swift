import Foundation

/// Why a browser pane's content process ended while its page was open.
///
/// The pane keeps its URL and history; Reload starts a new process. Ported
/// from cmux Next (`CmuxNextBrowser/Core/BrowserProcessExit.swift`) so a
/// Chromium pane in Classic reports the same reasons and error codes.
public struct BrowserProcessExit: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        /// The process crashed (a signal such as SIGSEGV, or a CHECK).
        case crashed
        /// Something outside the page ended it (`kill`, Activity Monitor,
        /// the system, or "Exit page" on a hung page).
        case killed
        case outOfMemory
        /// The process could not start.
        case launchFailed
        /// Code signature or integrity check failed.
        case integrityFailure
        /// Ended with a non-zero exit code for another reason.
        case abnormal
    }

    public var reason: Reason
    /// Raw `waitpid` status (or the engine's code), when one is known.
    public var code: Int?

    public init(reason: Reason, code: Int? = nil) {
        self.reason = reason
        self.code = code
    }

    /// Maps CEF's `cef_termination_status_t` (TS_ABNORMAL_TERMINATION = 0,
    /// TS_PROCESS_WAS_KILLED, TS_PROCESS_CRASHED, TS_PROCESS_OOM,
    /// TS_LAUNCH_FAILED, TS_INTEGRITY_FAILURE) and its error code.
    public static func chromium(terminationStatus status: Int, code: Int) -> BrowserProcessExit {
        let reason: Reason = switch status {
        case 1: .killed
        case 2: .crashed
        case 3: .outOfMemory
        case 4: .launchFailed
        case 5: .integrityFailure
        default: .abnormal
        }
        return BrowserProcessExit(reason: reason, code: code == 0 ? nil : code)
    }

    /// Nil for a normal end of a helper process (exit 0, a stop, or SIGTERM,
    /// which Chromium sends to helpers it no longer needs); otherwise why it
    /// ended. `status` is the raw `waitpid` status.
    public static func abnormalReason(waitStatus status: Int32) -> Reason? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff == 0 ? nil : .abnormal
        }
        if signal == 0x7f { return nil }
        switch signal {
        case SIGTERM: return nil
        case SIGKILL: return .killed
        default: return .crashed
        }
    }

    /// Error code text for the crashed page: "SIGSEGV" when the process ended
    /// from a signal, "exit 3" for an exit status. CEF reports the raw
    /// `waitpid` status on macOS; plain small numbers read as signals.
    public var codeDescription: String? {
        guard let code, code > 0 else { return nil }
        let signal = code & 0x7f
        if signal != 0, signal != 0x7f {
            return Self.signalName(signal) ?? "signal \(signal)"
        }
        let status = (code >> 8) & 0xff
        return status != 0 ? "exit \(status)" : String(code)
    }

    static func signalName(_ signal: Int) -> String? {
        switch signal {
        case 1: "SIGHUP"
        case 2: "SIGINT"
        case 3: "SIGQUIT"
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        case 15: "SIGTERM"
        default: nil
        }
    }
}
