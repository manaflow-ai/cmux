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

    /// The failure the page gets for an error of a checkpoint mutation. Only
    /// two answers are definite: the session host's resource error (its
    /// `mutation.indeterminate` included, which the page treats as
    /// uncertain by code) and `native.not_connected`, which was never sent.
    /// Anything else may have reached the session host, so it is
    /// `native.timed_out` and the page looks the key up before it retries:
    /// a timeout, a closed connection, a reply it could not decode.
    nonisolated init(mutating error: any Error) {
        switch error {
        case let failure as AgentPaneGitFailure:
            self = failure
        case DaemonError.command(_, _, let code, _, _):
            // Without a resource code the daemon still refused it outright.
            self = code == nil ? .failed : AgentPaneGitFailure(reading: error)
        case DaemonError.notConnected:
            self = .notConnected
        default:
            self = .timedOut
        }
    }
}
