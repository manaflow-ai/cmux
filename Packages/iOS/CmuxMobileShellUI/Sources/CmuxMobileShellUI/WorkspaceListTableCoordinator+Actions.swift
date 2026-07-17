#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

extension WorkspaceListTableCoordinator {
    func contextMenuActions(for workspace: MobileWorkspacePreview) -> [UIAction] {
        let capabilities = workspace.actionCapabilities
        var actions: [UIAction] = []
        if capabilities.supportsWorkspaceActions, let setPinned = configuration.setPinned {
            let action = UIAction(
                title: workspace.isPinned
                    ? L10n.string("mobile.workspace.unpin", defaultValue: "Unpin")
                    : L10n.string("mobile.workspace.pin", defaultValue: "Pin"),
                image: UIImage(systemName: workspace.isPinned ? "pin.slash" : "pin")
            ) { _ in
                setPinned(workspace.id, !workspace.isPinned)
            }
            action.accessibilityIdentifier = "MobileWorkspacePinButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        if capabilities.supportsWorkspaceActions, let renameRequest = configuration.renameRequest {
            let action = UIAction(
                title: L10n.string("mobile.workspace.rename.action", defaultValue: "Rename"),
                image: UIImage(systemName: "pencil")
            ) { _ in
                renameRequest(workspace.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceRenameButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        if capabilities.supportsReadStateActions, let setUnread = configuration.setUnread {
            let action = UIAction(
                title: readStateActionTitle(for: workspace),
                image: UIImage(systemName: readStateActionSystemImage(for: workspace))
            ) { _ in
                setUnread(workspace.id, !workspace.hasUnread)
            }
            action.accessibilityIdentifier = "MobileWorkspaceReadStateMenuButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        if capabilities.supportsCloseActions, let closeWorkspace = configuration.closeWorkspace {
            let action = UIAction(
                title: L10n.string("mobile.workspace.delete", defaultValue: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                closeWorkspace(workspace.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceDeleteMenuButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        return actions
    }

    func readStateActionTitle(for workspace: MobileWorkspacePreview) -> String {
        workspace.hasUnread
            ? L10n.string("mobile.workspace.markRead", defaultValue: "Mark as Read")
            : L10n.string("mobile.workspace.markUnread", defaultValue: "Mark as Unread")
    }

    func readStateActionSystemImage(for workspace: MobileWorkspacePreview) -> String {
        workspace.hasUnread ? "envelope.open" : "envelope.badge"
    }
}
#endif
