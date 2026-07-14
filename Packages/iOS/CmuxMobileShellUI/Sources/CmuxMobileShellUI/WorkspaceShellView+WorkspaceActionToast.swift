import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import SwiftUI

enum WorkspaceActionToastAction {
    case createWorkspace
    case createWorkspaceInGroup
    case createWorkspaceGroup
    case moveWorkspace
    case renameWorkspace
    case pinWorkspace
    case unpinWorkspace
    case markWorkspaceRead
    case markWorkspaceUnread
    case closeWorkspace
    case renameGroup
    case pinGroup
    case unpinGroup
    case ungroupGroup
    case deleteGroup
}

extension WorkspaceShellView {
    func handleWorkspaceActionResult(
        _ result: Result<Void, MobileWorkspaceMutationFailure>,
        action: WorkspaceActionToastAction
    ) {
        guard case let .failure(failure) = result else { return }
        withAnimation(.snappy(duration: 0.2)) {
            workspaceActionToast = WorkspaceActionToastContent(
                message: Self.workspaceActionFailureMessage(action: action, failure: failure)
            )
        }
    }

    func dismissWorkspaceActionToast() {
        withAnimation(.snappy(duration: 0.2)) {
            workspaceActionToast = nil
        }
    }

    static func workspaceActionFailureMessage(
        action: WorkspaceActionToastAction,
        failure: MobileWorkspaceMutationFailure
    ) -> String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.workspaceAction.failure.message",
                defaultValue: "Couldn't %@: %@."
            ),
            workspaceActionFailureActionText(action),
            workspaceActionFailureReasonText(failure)
        )
    }

    private static func workspaceActionFailureActionText(_ action: WorkspaceActionToastAction) -> String {
        switch action {
        case .createWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.createWorkspace", defaultValue: "create workspace")
        case .createWorkspaceInGroup:
            return L10n.string("mobile.workspaceAction.failure.action.createWorkspaceInGroup", defaultValue: "create workspace in group")
        case .createWorkspaceGroup:
            return L10n.string("mobile.workspaceAction.failure.action.createWorkspaceGroup", defaultValue: "create workspace group")
        case .moveWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.moveWorkspace", defaultValue: "move workspace")
        case .renameWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.renameWorkspace", defaultValue: "rename workspace")
        case .pinWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.pinWorkspace", defaultValue: "pin workspace")
        case .unpinWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.unpinWorkspace", defaultValue: "unpin workspace")
        case .markWorkspaceRead:
            return L10n.string("mobile.workspaceAction.failure.action.markWorkspaceRead", defaultValue: "mark workspace as read")
        case .markWorkspaceUnread:
            return L10n.string("mobile.workspaceAction.failure.action.markWorkspaceUnread", defaultValue: "mark workspace as unread")
        case .closeWorkspace:
            return L10n.string("mobile.workspaceAction.failure.action.closeWorkspace", defaultValue: "close workspace")
        case .renameGroup:
            return L10n.string("mobile.workspaceAction.failure.action.renameGroup", defaultValue: "rename group")
        case .pinGroup:
            return L10n.string("mobile.workspaceAction.failure.action.pinGroup", defaultValue: "pin group")
        case .unpinGroup:
            return L10n.string("mobile.workspaceAction.failure.action.unpinGroup", defaultValue: "unpin group")
        case .ungroupGroup:
            return L10n.string("mobile.workspaceAction.failure.action.ungroupGroup", defaultValue: "ungroup")
        case .deleteGroup:
            return L10n.string("mobile.workspaceAction.failure.action.deleteGroup", defaultValue: "delete group")
        }
    }

    private static func workspaceActionFailureReasonText(_ failure: MobileWorkspaceMutationFailure) -> String {
        switch failure {
        case let .notConnected(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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
        case .invalidWorkingDirectory:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.invalidWorkingDirectory",
                defaultValue: "the working directory isn't available on your Mac; choose another directory"
            )
        case .persistenceUnavailable:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.persistence",
                defaultValue: "your Mac could not safely reserve the request"
            )
        case .alreadyCompleted:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.alreadyCompleted",
                defaultValue: "your Mac already accepted the request; refresh workspaces before trying again"
            )
        case let .unsupported(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
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

    private static func trimmedWorkspaceActionHostDisplayName(_ hostDisplayName: String?) -> String? {
        guard let hostDisplayName = hostDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostDisplayName.isEmpty else {
            return nil
        }
        return hostDisplayName
    }
}
