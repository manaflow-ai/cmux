#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

extension WorkspaceListTableCoordinator {
    func contextMenuActions(
        for workspace: MobileWorkspacePreview,
        sourceView: UIView,
        renameTitle: String? = nil,
        contextMenuIdentifier: String? = nil
    ) -> [UIAction] {
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
        if capabilities.supportsWorkspaceActions,
           capabilities.supportsWorkspaceMetadata,
           let customizeRequest = configuration.customizeRequest {
            let action = UIAction(
                title: L10n.string("mobile.workspace.customize.action", defaultValue: "Customize"),
                image: UIImage(systemName: "slider.horizontal.3")
            ) { _ in
                customizeRequest(workspace.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceCustomizeButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        if capabilities.supportsWorkspaceActions, let renameRequest = configuration.renameRequest {
            let action = UIAction(
                title: renameTitle
                    ?? L10n.string("mobile.workspace.rename.action", defaultValue: "Rename"),
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
        if capabilities.supportsCloseActions, configuration.closeWorkspace != nil {
            let action = UIAction(
                title: L10n.string("mobile.workspace.delete", defaultValue: "Delete"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self, weak sourceView] _ in
                guard let self, let sourceView else { return }
                requestWorkspaceCloseConfirmation(
                    for: workspace,
                    sourceView: sourceView,
                    waitsForContextMenuDismissal: true,
                    contextMenuIdentifier: contextMenuIdentifier
                        ?? workspace.id.rawValue
                )
            }
            action.accessibilityIdentifier = "MobileWorkspaceDeleteMenuButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        return actions
    }

    func contextMenuActions(
        for group: MobileWorkspaceGroupPreview
    ) -> [UIMenuElement] {
        let capabilities = configuration.workspacesByID[group.anchorWorkspaceID]?
            .actionCapabilities ?? .none
        var sections: [UIMenuElement] = []
        var groupActions: [UIAction] = []

        if capabilities.supportsGroupActions,
           let setGroupPinned = configuration.setGroupPinned {
            let action = UIAction(
                title: group.isPinned
                    ? L10n.string("mobile.workspaceGroup.unpin", defaultValue: "Unpin Group")
                    : L10n.string("mobile.workspaceGroup.pin", defaultValue: "Pin Group"),
                image: UIImage(systemName: group.isPinned ? "pin.slash" : "pin")
            ) { _ in
                setGroupPinned(group.id, !group.isPinned)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupPinButton-\(group.id.rawValue)"
            groupActions.append(action)
        }
        if capabilities.supportsGroupActions,
           let renameWorkspaceGroupRequest = configuration.renameWorkspaceGroupRequest {
            let action = UIAction(
                title: L10n.string(
                    "mobile.workspaceGroup.rename.action",
                    defaultValue: "Rename Group"
                ),
                image: UIImage(systemName: "pencil")
            ) { _ in
                renameWorkspaceGroupRequest(group.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupRenameButton-\(group.id.rawValue)"
            groupActions.append(action)
        }
        if let createWorkspaceInGroup = configuration.createWorkspaceInGroup {
            let action = UIAction(
                title: L10n.string(
                    "mobile.workspaceGroup.newWorkspace",
                    defaultValue: "New Workspace in Group"
                ),
                image: UIImage(systemName: "plus")
            ) { _ in
                createWorkspaceInGroup(group.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupNewWorkspace-\(group.id.rawValue)"
            groupActions.append(action)
        }
        if !groupActions.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: groupActions))
        }

        var destructiveActions: [UIAction] = []
        if capabilities.supportsGroupActions,
           let ungroupWorkspaceGroupRequest = configuration.ungroupWorkspaceGroupRequest {
            let action = UIAction(
                title: L10n.string(
                    "mobile.workspaceGroup.ungroup",
                    defaultValue: "Ungroup (Keep Workspaces)"
                ),
                image: UIImage(systemName: "rectangle.3.group"),
                attributes: .destructive
            ) { _ in
                ungroupWorkspaceGroupRequest(group.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupUngroupButton-\(group.id.rawValue)"
            destructiveActions.append(action)
        }
        if capabilities.supportsGroupActions,
           let deleteWorkspaceGroupRequest = configuration.deleteWorkspaceGroupRequest {
            let action = UIAction(
                title: L10n.string(
                    "mobile.workspaceGroup.delete",
                    defaultValue: "Delete Group (Close Workspaces)"
                ),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { _ in
                deleteWorkspaceGroupRequest(group.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupDeleteButton-\(group.id.rawValue)"
            destructiveActions.append(action)
        }
        if !destructiveActions.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: destructiveActions))
        }
        return sections
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
