import CmuxMobileShell
import CmuxMobileSupport
import CmuxMobileToast
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
        toasts.present(.failure(
            Self.workspaceActionFailureReasonText(failure),
            title: Self.workspaceActionFailureTitle(action: action),
            // One key per action: a repeat of the same failed action re-bumps
            // the visible toast (even if the reason changed) instead of
            // queueing near-duplicates.
            coalescingKey: "workspaceAction.failure.\(action)"
        ))
    }

    /// The toast's bold first line ("Couldn't rename workspace"). Static so
    /// message-composition tests exercise it without building the view.
    static func workspaceActionFailureTitle(action: WorkspaceActionToastAction) -> String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.workspaceAction.failure.titleFormat",
                defaultValue: "Couldn't %@"
            ),
            workspaceActionFailureActionText(action)
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

    /// The toast's secondary line: the failure reason as a standalone sentence.
    static func workspaceActionFailureReasonText(_ failure: MobileWorkspaceMutationFailure) -> String {
        switch failure {
        case let .notConnected(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.notConnected.host",
                        defaultValue: "Not connected to %@."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.notConnected.generic",
                defaultValue: "Not connected to your Mac."
            )
        case let .requestTimedOut(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.timedOut.host",
                        defaultValue: "The request to %@ timed out."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.timedOut.generic",
                defaultValue: "The request to your Mac timed out."
            )
        case let .authorizationFailed(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.authorization.host",
                        defaultValue: "%@ didn't authorize the request."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.authorization.generic",
                defaultValue: "Your Mac didn't authorize the request."
            )
        case let .busy(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.busy.host",
                        defaultValue: "%@ is finishing another workspace action."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.busy.generic",
                defaultValue: "Another workspace action is still finishing."
            )
        case let .rejected(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.rejected.host",
                        defaultValue: "%@ rejected the request."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.rejected.generic",
                defaultValue: "Your Mac rejected the request."
            )
        case .invalidWorkingDirectory:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.invalidWorkingDirectory",
                defaultValue: "The working directory isn't available on your Mac; choose another directory."
            )
        case .persistenceUnavailable:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.persistence",
                defaultValue: "Your Mac could not safely reserve the request."
            )
        case .alreadyCompleted:
            return L10n.string(
                "mobile.workspaceAction.failure.reason.alreadyCompleted",
                defaultValue: "Your Mac already accepted the request; refresh workspaces before trying again."
            )
        case let .unsupported(hostDisplayName):
            if let hostDisplayName = trimmedWorkspaceActionHostDisplayName(hostDisplayName) {
                return String.localizedStringWithFormat(
                    L10n.string(
                        "mobile.workspaceAction.failure.reason.unsupported.host",
                        defaultValue: "%@ doesn't support that action."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.unsupported.generic",
                defaultValue: "Your Mac doesn't support that action."
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
