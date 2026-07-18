import CmuxMobileShell
import CmuxMobileSupport
import Foundation

enum WorkspaceActionKind {
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
        action: WorkspaceActionKind
    ) {
        guard case let .failure(failure) = result else { return }
        toastPresenter.present(
            .error(
                title: .verbatim(workspaceActionFailureTitle(action: action)),
                message: .verbatim(workspaceActionFailureReasonText(failure)),
                coalescingKey: "workspace-action-failure",
                accessibilityIdentifier: "MobileWorkspaceActionToast"
            )
        )
    }

    private func workspaceActionFailureTitle(action: WorkspaceActionKind) -> String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.workspaceAction.failure.title",
                defaultValue: "Couldn't %@"
            ),
            workspaceActionFailureActionText(action)
        )
    }

    private func workspaceActionFailureActionText(_ action: WorkspaceActionKind) -> String {
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

    private func workspaceActionFailureReasonText(_ failure: MobileWorkspaceMutationFailure) -> String {
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
                        defaultValue: "Timed out talking to %@."
                    ),
                    hostDisplayName
                )
            }
            return L10n.string(
                "mobile.workspaceAction.failure.reason.timedOut.generic",
                defaultValue: "Timed out talking to your Mac."
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

    private func trimmedWorkspaceActionHostDisplayName(_ hostDisplayName: String?) -> String? {
        guard let hostDisplayName = hostDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostDisplayName.isEmpty else {
            return nil
        }
        return hostDisplayName
    }
}
