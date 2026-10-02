import CmuxNextAgentPane
import CmuxNextDaemon
import Foundation

extension AgentPaneGitFailure {
    /// The failure the page gets for an error of a sent git read. A resource
    /// error the session host answered keeps its code, details and
    /// retryable; a request that may have gone out unanswered (a timeout, the
    /// connection closing while it was pending) is `native.timed_out`.
    nonisolated init(reading error: any Error) {
        switch error {
        case let failure as AgentPaneGitFailure:
            self = failure
        case DaemonError.command(_, _, let code?, let details, let retryable):
            let json = details.flatMap { try? JSONEncoder().encode($0) }
            self.init(code: code, details: json, retryable: retryable, origin: .sessionHost)
        case DaemonError.notConnected:
            self = .notConnected
        case DaemonError.timedOut, DaemonError.connectionClosed, DaemonError.daemonShutdown:
            self = .timedOut
        default:
            self = .failed
        }
    }

    /// The failure the page gets for an error of a checkpoint mutation.
    nonisolated init(mutating error: any Error) {
        self.init(reading: error)
    }
}
