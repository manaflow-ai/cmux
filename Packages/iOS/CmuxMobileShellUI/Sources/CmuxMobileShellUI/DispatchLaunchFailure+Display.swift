import CmuxMobileShell
import CmuxMobileSupport
import Foundation

extension DispatchLaunchFailure {
    /// The human reason printed under a REJECTED stamp. Concrete per failure so
    /// the user knows what to fix, not just that something went wrong.
    func displayReason(agentName: String?) -> String {
        switch self {
        case .notConnected:
            return L10n.string(
                "mobile.dispatch.failure.notConnected",
                defaultValue: "The Mac is offline. Reconnect and dispatch again."
            )
        case .requestTimedOut:
            return L10n.string(
                "mobile.dispatch.failure.timedOut",
                defaultValue: "The Mac didn't answer in time. Dispatch again."
            )
        case .authorizationFailed:
            return L10n.string(
                "mobile.dispatch.failure.authorization",
                defaultValue: "This phone is no longer authorized for that Mac."
            )
        case .agentNotInstalled:
            let name = agentName ?? L10n.string("mobile.dispatch.failure.agentFallbackName", defaultValue: "The agent")
            return String(
                format: L10n.string(
                    "mobile.dispatch.failure.agentNotInstalled",
                    defaultValue: "%@ isn't installed on the Mac."
                ),
                name
            )
        case .directoryNotFound:
            return L10n.string(
                "mobile.dispatch.failure.directoryNotFound",
                defaultValue: "That folder no longer exists on the Mac."
            )
        case .promptTooLong:
            return L10n.string(
                "mobile.dispatch.failure.promptTooLong",
                defaultValue: "The brief is too long to dispatch."
            )
        case let .rejected(message):
            let base = L10n.string(
                "mobile.dispatch.failure.rejected",
                defaultValue: "The Mac rejected this dispatch."
            )
            if let message, !message.isEmpty {
                return base + " (\(message))"
            }
            return base
        }
    }
}
