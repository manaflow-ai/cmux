import CmuxHomeCore
import CmuxNextDaemon
import Foundation

/// A failed cloud proxy reply as the Home sees it (home-cloud-proxy.md
/// section 6): the `HomeRejection` the store acts on, and whether the daemon
/// held no usable lease. Split out of `CloudHomeSource` (cx-59n8.6).
nonisolated struct CloudReplyError {
    let error: any Error

    init(_ error: any Error) {
        self.error = error
    }

    /// The daemon holds no usable lease: none (`cloud_signed_out`), or one
    /// that expired (`cloud_session_expired`, possibly one another trusted
    /// local client set).
    var isNoLease: Bool {
        guard case .command(_, _, let code, _, _) = error as? DaemonError else { return false }
        return code == "cloud_signed_out" || code == "cloud_session_expired"
    }

    /// The daemon's answer as `HomeRejection`.
    var rejection: HomeRejection {
        switch error {
        case let rejection as HomeRejection: rejection
        case let error as DaemonError: Self.rejection(error)
        default: .indeterminate
        }
    }

    private static func rejection(_ error: DaemonError) -> HomeRejection {
        switch error {
        case .command(_, let message, let code, _, let retryable):
            let reason = error.rejectReason ?? message
            switch code {
            case "cloud_conversation_rejected":
                if retryable == true { return .rateLimited(retryAfter: nil) }
                return reason == "forbidden" ? .notAuthorized : .invalid(reason)
            // Refused before the owner saw it: nothing committed; resent after a
            // new lease (no lease at all: the source asks for one, `reply`).
            case "cloud_signed_out", "cloud_session_expired", "cloud_unauthenticated": return .ownerUnreachable
            // The outcome of a mutation is unknown: resend with the same key.
            case "cloud_unavailable": return .indeterminate
            default: return .invalid(reason)
            }
        case .notConnected, .missingCapabilities: return .ownerUnreachable
        default: return .indeterminate
        }
    }
}
