import Foundation

extension BrowserPageProcessExit {
    /// Maps CEF's `cef_termination_status_t` (TS_ABNORMAL_TERMINATION = 0,
    /// TS_PROCESS_WAS_KILLED, TS_PROCESS_CRASHED, TS_PROCESS_OOM,
    /// TS_LAUNCH_FAILED, TS_INTEGRITY_FAILURE) and its error code, which CEF
    /// gives as the raw `waitpid` status on macOS. Launch and integrity
    /// failures map to ``Kind/other``.
    public static func chromium(terminationStatus status: Int, code: Int) -> BrowserPageProcessExit {
        let kind: Kind = switch status {
        case 1: .killed
        case 2: .crashed
        case 3: .outOfMemory
        default: .other
        }
        return BrowserPageProcessExit(kind: kind, status: code == 0 ? nil : Int32(truncatingIfNeeded: code))
    }

    /// Nil for a normal end of a helper process (exit 0, a stop, or SIGTERM,
    /// which Chromium sends to helpers it no longer needs); otherwise why it
    /// ended. `status` is the raw `waitpid` status.
    public static func helperExitKind(waitStatus status: Int32) -> Kind? {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff == 0 ? nil : .other
        }
        if signal == 0x7f { return nil }
        switch signal {
        case SIGTERM: return nil
        case SIGKILL: return .killed
        default: return .crashed
        }
    }

    /// Error code text for the crashed-page view: "SIGSEGV" when the process
    /// ended from a signal, "exit 3" for an exit status. Plain small numbers
    /// read as signals (CEF reports the raw `waitpid` status).
    public var codeDescription: String? {
        Self.codeDescription(status: status)
    }

    static func codeDescription(status: Int32?) -> String? {
        guard let code = status, code > 0 else { return nil }
        let signal = code & 0x7f
        if signal != 0, signal != 0x7f {
            return signalName(signal) ?? "signal \(signal)"
        }
        let exitStatus = (code >> 8) & 0xff
        return exitStatus != 0 ? "exit \(exitStatus)" : String(code)
    }

    static func signalName(_ signal: Int32) -> String? {
        switch signal {
        case SIGHUP: "SIGHUP"
        case SIGINT: "SIGINT"
        case SIGQUIT: "SIGQUIT"
        case SIGILL: "SIGILL"
        case SIGTRAP: "SIGTRAP"
        case SIGABRT: "SIGABRT"
        case SIGFPE: "SIGFPE"
        case SIGKILL: "SIGKILL"
        case SIGBUS: "SIGBUS"
        case SIGSEGV: "SIGSEGV"
        case SIGPIPE: "SIGPIPE"
        case SIGTERM: "SIGTERM"
        default: nil
        }
    }
}
