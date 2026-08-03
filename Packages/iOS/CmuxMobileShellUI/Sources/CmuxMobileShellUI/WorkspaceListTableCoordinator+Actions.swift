#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import UIKit

extension WorkspaceListTableCoordinator {
    func contextMenuActions(
        for workspace: MobileWorkspacePreview,
        sourceView: UIView
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
        } else if capabilities.supportsWorkspaceActions, let renameRequest = configuration.renameRequest {
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
                    waitsForContextMenuDismissal: true
                )
            }
            action.accessibilityIdentifier = "MobileWorkspaceDeleteMenuButton-\(workspace.id.rawValue)"
            actions.append(action)
        }
        return actions
    }

    func contextMenuActions(
        for group: MobileWorkspaceGroupPreview,
        sourceView: UIView
    ) -> [UIMenuElement] {
        let capabilities = configuration.workspacesByID[group.anchorWorkspaceID]?
            .actionCapabilities ?? .none
        var sections: [UIMenuElement] = []

        var metadata: [UIAction] = []
        if capabilities.supportsGroupActions, let setPinned = configuration.setGroupPinned {
            let action = UIAction(
                title: group.isPinned
                    ? L10n.string("mobile.workspaceGroup.unpin", defaultValue: "Unpin Group")
                    : L10n.string("mobile.workspaceGroup.pin", defaultValue: "Pin Group"),
                image: UIImage(systemName: group.isPinned ? "pin.slash" : "pin")
            ) { _ in
                setPinned(group.id, !group.isPinned)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupPinButton-\(group.id.rawValue)"
            metadata.append(action)
        }
        if capabilities.supportsGroupActions, configuration.renameWorkspaceGroup != nil {
            let action = UIAction(
                title: L10n.string("mobile.workspaceGroup.rename.action", defaultValue: "Rename Group"),
                image: UIImage(systemName: "pencil")
            ) { [weak self, weak sourceView] _ in
                guard let self, let sourceView else { return }
                requestGroupPresentation(for: group, sourceView: sourceView, kind: .rename)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupRenameButton-\(group.id.rawValue)"
            metadata.append(action)
        }
        if !metadata.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: metadata))
        }

        if let create = configuration.createWorkspaceInGroup {
            let action = UIAction(
                title: L10n.string("mobile.workspaceGroup.newWorkspace", defaultValue: "New Workspace in Group"),
                image: UIImage(systemName: "plus")
            ) { _ in
                create(group.id)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupNewWorkspace-\(group.id.rawValue)"
            sections.append(UIMenu(options: .displayInline, children: [action]))
        }

        var destructive: [UIAction] = []
        if capabilities.supportsGroupActions, configuration.ungroupWorkspaceGroup != nil {
            let action = UIAction(
                title: L10n.string("mobile.workspaceGroup.ungroup", defaultValue: "Ungroup (Keep Workspaces)"),
                image: UIImage(systemName: "rectangle.3.group"),
                attributes: .destructive
            ) { [weak self, weak sourceView] _ in
                guard let self, let sourceView else { return }
                requestGroupPresentation(for: group, sourceView: sourceView, kind: .ungroup)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupUngroupButton-\(group.id.rawValue)"
            destructive.append(action)
        }
        if capabilities.supportsGroupActions, configuration.deleteWorkspaceGroup != nil {
            let action = UIAction(
                title: L10n.string("mobile.workspaceGroup.delete", defaultValue: "Delete Group (Close Workspaces)"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive
            ) { [weak self, weak sourceView] _ in
                guard let self, let sourceView else { return }
                requestGroupPresentation(for: group, sourceView: sourceView, kind: .delete)
            }
            action.accessibilityIdentifier = "MobileWorkspaceGroupDeleteButton-\(group.id.rawValue)"
            destructive.append(action)
        }
        if !destructive.isEmpty {
            sections.append(UIMenu(options: .displayInline, children: destructive))
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
