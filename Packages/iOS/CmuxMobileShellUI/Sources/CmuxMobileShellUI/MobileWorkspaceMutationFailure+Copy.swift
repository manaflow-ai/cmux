import CmuxMobileShell
import CmuxMobileSupport
import Foundation

extension MobileWorkspaceMutationFailure {
    /// The localized reason clause shared by the workspace-action failure toast
    /// and the agent-launch composer's inline error ("not connected to your
    /// Mac", "was rejected by Aziz's Mac", …).
    var reasonText: String {
        switch self {
        case let .notConnected(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.notConnected.host",
                        defaultValue: "not connected to %@"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.notConnected.generic",
                defaultValue: "not connected to your Mac"
            )
        case let .requestTimedOut(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.timedOut.host",
                        defaultValue: "timed out talking to %@"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.timedOut.generic",
                defaultValue: "timed out talking to your Mac"
            )
        case let .authorizationFailed(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.authorization.host",
                        defaultValue: "was not authorized by %@"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.authorization.generic",
                defaultValue: "was not authorized by your Mac"
            )
        case let .busy(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.busy.host",
                        defaultValue: "%@ is finishing another workspace action"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.busy.generic",
                defaultValue: "another workspace action is still finishing"
            )
        case let .rejected(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.rejected.host",
                        defaultValue: "was rejected by %@"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.rejected.generic",
                defaultValue: "was rejected by your Mac"
            )
        case let .unsupported(hostDisplayName):
            if let hostDisplayName = Self.trimmedHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.unsupported.host",
                        defaultValue: "%@ doesn't support that action"
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.unsupported.generic",
                defaultValue: "your Mac doesn't support that action"
            )
        }
    }

    private static func trimmedHostDisplayName(_ hostDisplayName: String?) -> String? {
        guard let hostDisplayName = hostDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostDisplayName.isEmpty else {
            return nil
        }
        return hostDisplayName
    }
}
