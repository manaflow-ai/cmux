#if os(iOS)
import CmuxMobileShell
import CmuxMobileSupport
import Foundation

enum WorkspaceActionToastAction {
    case createWorkspace
    case createWorkspaceInGroup
    case createWorkspaceGroup
    case moveWorkspace
    case renameWorkspace
    case updateWorkspaceDescription
    case updateWorkspaceColor
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

enum WorkspaceActionFailurePolicy {
    static func title(action: WorkspaceActionToastAction) -> String {
        String.localizedStringWithFormat(
            L10n.string("mobile.workspaceAction.failure.titleFormat", defaultValue: "Couldn't %@"),
            actionText(action)
        )
    }

    private static func actionText(_ action: WorkspaceActionToastAction) -> String {
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
        case .updateWorkspaceDescription:
            return L10n.string("mobile.workspaceAction.failure.action.updateWorkspaceDescription", defaultValue: "update workspace description")
        case .updateWorkspaceColor:
            return L10n.string("mobile.workspaceAction.failure.action.updateWorkspaceColor", defaultValue: "update workspace color")
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

    static func reason(_ failure: MobileWorkspaceMutationFailure) -> String {
        switch failure {
        case let .notConnected(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.notConnected.host",
                hostDefault: "Not connected to %@.",
                genericKey: "mobile.workspaceAction.failure.reason.notConnected.generic",
                genericDefault: "Not connected to your Mac."
            )
        case let .requestTimedOut(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.timedOut.host",
                hostDefault: "The request to %@ timed out.",
                genericKey: "mobile.workspaceAction.failure.reason.timedOut.generic",
                genericDefault: "The request to your Mac timed out."
            )
        case let .authorizationFailed(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.authorization.host",
                hostDefault: "%@ didn't authorize the request.",
                genericKey: "mobile.workspaceAction.failure.reason.authorization.generic",
                genericDefault: "Your Mac didn't authorize the request."
            )
        case let .busy(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.busy.host",
                hostDefault: "%@ is finishing another workspace action.",
                genericKey: "mobile.workspaceAction.failure.reason.busy.generic",
                genericDefault: "Another workspace action is still finishing."
            )
        case let .rejected(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.rejected.host",
                hostDefault: "%@ rejected the request.",
                genericKey: "mobile.workspaceAction.failure.reason.rejected.generic",
                genericDefault: "Your Mac rejected the request."
            )
        case .invalidWorkingDirectory:
            return L10n.string("mobile.workspaceAction.failure.reason.invalidWorkingDirectory", defaultValue: "The working directory isn't available on your Mac; choose another directory.")
        case .persistenceUnavailable:
            return L10n.string("mobile.workspaceAction.failure.reason.persistence", defaultValue: "Your Mac could not safely reserve the request.")
        case .alreadyCompleted:
            return L10n.string("mobile.workspaceAction.failure.reason.alreadyCompleted", defaultValue: "Your Mac already accepted the request; refresh workspaces before trying again.")
        case let .unsupported(host):
            return hostMessage(
                host,
                hostKey: "mobile.workspaceAction.failure.reason.unsupported.host",
                hostDefault: "%@ doesn't support that action.",
                genericKey: "mobile.workspaceAction.failure.reason.unsupported.generic",
                genericDefault: "Your Mac doesn't support that action."
            )
        }
    }

    private static func hostMessage(
        _ host: String?,
        hostKey: StaticString,
        hostDefault: String.LocalizationValue,
        genericKey: StaticString,
        genericDefault: String.LocalizationValue
    ) -> String {
        guard let host = host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return L10n.string(genericKey, defaultValue: genericDefault)
        }
        return String.localizedStringWithFormat(
            L10n.string(hostKey, defaultValue: hostDefault),
            host
        )
    }
}
#endif
