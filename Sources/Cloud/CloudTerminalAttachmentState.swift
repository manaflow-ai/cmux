import Foundation

/// Why a native cloud pane is not attached right now.
enum CloudTerminalAttachmentInterruption: Equatable, Sendable {
    /// The daemon accepted the socket but did not finish identify → attach
    /// within the handshake deadline.
    case handshakeTimedOut
    /// The attached stream went quiet and did not answer a probe.
    case livenessTimedOut
    /// The transport closed, overflowed, or the daemon detached the view.
    case transportClosed
    /// The daemon refused the attachment or a sizing request.
    case rejected(String)
    /// The Mac could not map the terminal to an attachable surface yet.
    case unresolved(String)

    /// A stable, code-like form for the unified log. Free text stays out of
    /// it; see ``detail``.
    var logDescription: String {
        switch self {
        case .handshakeTimedOut: return "handshake-timeout"
        case .livenessTimedOut: return "liveness-timeout"
        case .transportClosed: return "transport-closed"
        case .rejected: return "rejected"
        case .unresolved: return "unresolved"
        }
    }

    /// The free-text part of the reason, logged privately.
    var detail: String? {
        switch self {
        case .handshakeTimedOut, .livenessTimedOut, .transportClosed: return nil
        case let .rejected(reason), let .unresolved(reason): return reason
        }
    }

    var localizedDescription: String {
        switch self {
        case .handshakeTimedOut:
            return String(
                localized: "cloudPane.attachment.reason.handshakeTimedOut",
                defaultValue: "the machine did not finish the attach handshake"
            )
        case .livenessTimedOut:
            return String(
                localized: "cloudPane.attachment.reason.livenessTimedOut",
                defaultValue: "the connection stopped answering"
            )
        case .transportClosed:
            return String(
                localized: "cloudPane.attachment.reason.transportClosed",
                defaultValue: "the connection closed"
            )
        case let .rejected(reason):
            return String(
                format: String(
                    localized: "cloudPane.attachment.reason.rejected",
                    defaultValue: "the machine rejected the attachment (%@)"
                ),
                reason
            )
        case let .unresolved(reason):
            return String(
                format: String(
                    localized: "cloudPane.attachment.reason.unresolved",
                    defaultValue: "cmux-tui has not reported this terminal yet (%@)"
                ),
                reason
            )
        }
    }
}

/// The attachment as the pane shows it. Derived from the session's phase; the
/// pane never drives transitions.
enum CloudTerminalAttachmentState: Equatable, Sendable {
    case attaching(attempt: Int)
    case attached
    case reconnecting(attempt: Int, reason: CloudTerminalAttachmentInterruption)
    case ended
}
