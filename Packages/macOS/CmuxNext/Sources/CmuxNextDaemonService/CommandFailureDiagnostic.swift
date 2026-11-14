import CmuxNextDaemon

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
