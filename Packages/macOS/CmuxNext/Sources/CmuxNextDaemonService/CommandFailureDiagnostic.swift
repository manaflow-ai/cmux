import CmuxNextDaemon
import os

extension DaemonService {
    /// Preserve a caller's immediate offline refusal while recording the
    /// same diagnostic as a command that loses its connection after dispatch.
    public func send(_ label: String, checkingConnection: () -> Bool,
                     logFailure: ((String, any Error) -> Void)? = nil, _ body: @escaping DaemonCommandBody) {
        guard checkingConnection() else {
            if let logFailure { logFailure(label, DaemonError.notConnected) }
            else { logCommandFailure(label, error: DaemonError.notConnected) }
            return
        }
        send(label, body)
    }

    /// Also used when an action refuses before sending (an already offline
    /// connection). Logging does not choose or change the action's notice.
    public func logCommandFailure(_ label: String, error: any Error) {
        logger.error("\(CommandFailureDiagnostic(label: label, error: error).message, privacy: .public)")
    }
}

/// App-log context only: this text never chooses a notice or a command outcome.
struct CommandFailureDiagnostic {
    let label: String
    let error: any Error

    var message: String {
        let daemon = error as? DaemonError
        let kind: String
        if daemon?.isMissedDeadline == true {
            kind = "timeout"
        } else if daemon?.isLostConnection == true {
            kind = "disconnected"
        } else if case .command = daemon {
            kind = "refused"
        } else {
            kind = "other"
        }
        let outcome = daemon?.isMissedDeadline == true ? "outcome unknown" : "failed"
        return "\(label) error_kind=\(kind) \(outcome): \(error)"
    }
}
