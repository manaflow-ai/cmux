import AppKit
import Foundation
public import SwiftUI

/// The full right-click context menu for a workspace row in the vertical-tabs
/// sidebar.
///
/// This view is a faithful lift of the legacy `TabItemView.workspaceContextMenu`
/// builder. Every input is an immutable value snapshot (``SidebarWorkspaceContextMenuData``)
/// or a closure (``SidebarWorkspaceContextMenuActions``): the owning row
/// precomputes the localized labels, the target id list, the available colors,
/// the destination windows, and every disabled flag, so the menu honors the
/// list snapshot-boundary rule and never reaches back into a live workspace,
/// tab-manager, or app-delegate store.
///
/// Button ordering, dividers, keyboard-shortcut bindings, and the `disabled`
/// conditions reproduce the legacy menu exactly; the only structural change is
/// that the workspace-group section is composed from
/// ``SidebarWorkspaceGroupContextMenuSection``.
public struct SidebarWorkspaceContextMenu: View {
    let data: SidebarWorkspaceContextMenuData
    let actions: SidebarWorkspaceContextMenuActions

    /// Creates the workspace context menu.
    /// - Parameters:
    ///   - data: Immutable snapshot of every label, id, flag, and list the menu renders.
    ///   - actions: Closure bundle invoked by the menu's buttons.
    public init(
        data: SidebarWorkspaceContextMenuData,
        actions: SidebarWorkspaceContextMenuActions
    ) {
        self.data = data
        self.actions = actions
    }

    public var body: some View {
        let targetIds = data.targetIds

        Button(data.pinLabel) {
            actions.onPin()
        }
        .disabled(!data.pinEnabled)

        SidebarWorkspaceGroupContextMenuSection(
            groups: data.groups,
            eligibleTargetIds: data.eligibleGroupTargetIds,
            allTargetsInSameGroupId: data.allTargetsInSameGroupId,
            hasAnyGroupedTarget: data.hasAnyGroupedTarget,
            isMulti: data.isMulti,
            groupSelectedShortcutKey: data.groupSelectedShortcutKey,
            groupSelectedShortcutModifiers: data.groupSelectedShortcutModifiers,
            onNewGroup: actions.onNewGroup,
            onMoveToGroup: actions.onMoveToGroup,
            onRemoveFromGroup: actions.onRemoveFromGroup
        )

        let renameLabel = String(
            localized: "contextMenu.renameWorkspace",
            defaultValue: "Rename Workspace…",
            bundle: .main
        )
        if let key = data.renameShortcutKey {
            Button(renameLabel) {
                actions.onRename()
            }
            .keyboardShortcut(key, modifiers: data.renameShortcutModifiers)
        } else {
            Button(renameLabel) {
                actions.onRename()
            }
        }

        if data.hasCustomTitle {
            Button(String(
                localized: "contextMenu.removeCustomWorkspaceName",
                defaultValue: "Remove Custom Workspace Name",
                bundle: .main
            )) {
                actions.onRemoveCustomName()
            }
        }

        if !data.isMulti {
            let editDescriptionLabel = String(
                localized: "contextMenu.editWorkspaceDescription",
                defaultValue: "Edit Workspace Description…",
                bundle: .main
            )
            if let key = data.editDescriptionShortcutKey {
                Button(editDescriptionLabel) {
                    actions.onEditDescription()
                }
                .keyboardShortcut(key, modifiers: data.editDescriptionShortcutModifiers)
            } else {
                Button(editDescriptionLabel) {
                    actions.onEditDescription()
                }
            }

            if data.hasCustomDescription {
                Button(String(
                    localized: "contextMenu.clearWorkspaceDescription",
                    defaultValue: "Clear Workspace Description",
                    bundle: .main
                )) {
                    actions.onClearDescription()
                }
            }
        }

        if data.hasRemoteContextMenuTargets {
            Divider()

            Button(data.reconnectLabel) {
                actions.onReconnect()
            }
            .disabled(data.allRemoteTargetsConnecting)

            Button(data.disconnectLabel) {
                actions.onDisconnect()
            }
            .disabled(data.allRemoteTargetsDisconnected)
        }

        Menu(String(
            localized: "contextMenu.workspaceColor",
            defaultValue: "Workspace Color",
            bundle: .main
        )) {
            if data.hasCustomColor {
                Button {
                    actions.onApplyColor(nil, targetIds)
                } label: {
                    Label(
                        String(localized: "contextMenu.clearColor", defaultValue: "Clear Color", bundle: .main),
                        systemImage: "xmark.circle"
                    )
                }
            }

            Button {
                actions.onChooseCustomColor(targetIds)
            } label: {
                Label(
                    String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…", bundle: .main),
                    systemImage: "paintpalette"
                )
            }

            if !data.colorPalette.isEmpty {
                Divider()
            }

            ForEach(data.colorPalette) { entry in
                Button {
                    actions.onApplyColor(entry.hex, targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: actions.colorSwatchImage(entry.hex))
                    }
                }
            }
        }

        if let copyableSidebarSSHError = data.copyableSidebarSSHError {
            Button(String(
                localized: "contextMenu.copySshError",
                defaultValue: "Copy SSH Error",
                bundle: .main
            )) {
                actions.onCopySshError(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up", bundle: .main)) {
            actions.onMoveUp()
        }
        .disabled(data.isFirstRow)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down", bundle: .main)) {
            actions.onMoveDown()
        }
        .disabled(data.isLastRow)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top", bundle: .main)) {
            actions.onMoveToTop(targetIds)
        }
        .disabled(targetIds.isEmpty)

        let moveMenuTitle = data.isMulti
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window", bundle: .main)
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window", bundle: .main)
        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window", bundle: .main)) {
                actions.onMoveToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !data.windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(data.windowMoveTargets) { target in
                Button(target.label) {
                    actions.onMoveToWindow(targetIds, target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = data.closeShortcutKey {
            Button(data.closeLabel) {
                actions.onClose(targetIds)
            }
            .keyboardShortcut(key, modifiers: data.closeShortcutModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(data.closeLabel) {
                actions.onClose(targetIds)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(
            localized: "contextMenu.closeOtherWorkspaces",
            defaultValue: "Close Other Workspaces",
            bundle: .main
        )) {
            actions.onCloseOthers(targetIds)
        }
        .disabled(data.closeOthersDisabled)

        Button(String(
            localized: "contextMenu.closeWorkspacesBelow",
            defaultValue: "Close Workspaces Below",
            bundle: .main
        )) {
            actions.onCloseBelow()
        }
        .disabled(data.isLastRow)

        Button(String(
            localized: "contextMenu.closeWorkspacesAbove",
            defaultValue: "Close Workspaces Above",
            bundle: .main
        )) {
            actions.onCloseAbove()
        }
        .disabled(data.isFirstRow)

        Divider()

        Button(data.markReadLabel) {
            actions.onMarkRead(targetIds)
        }
        .disabled(!data.canMarkRead)

        Button(data.markUnreadLabel) {
            actions.onMarkUnread(targetIds)
        }
        .disabled(!data.canMarkUnread)

        Button(data.clearLatestNotificationLabel) {
            actions.onClearLatestNotifications(targetIds)
        }
        .disabled(!data.hasLatestNotifications)

        Menu(String(localized: "contextMenu.notifications", defaultValue: "Notifications", bundle: .main)) {
            if data.workspaceNotifications.isEmpty {
                Button(String(localized: "contextMenu.notifications.empty", defaultValue: "No Notifications", bundle: .main)) {}
                    .disabled(true)
            } else {
                ForEach(data.workspaceNotifications) { notification in
                    Button(notification.title) {
                        actions.onOpenNotification(notification.id)
                    }
                }
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        Button(data.copyWorkspaceIDLabel) {
            actions.onCopyWorkspaceIds(targetIds)
        }
        .disabled(targetIds.isEmpty)

        Button(data.copyWorkspaceLinkLabel) {
            actions.onCopyWorkspaceLinks(targetIds)
        }
        .disabled(targetIds.isEmpty)

        if !data.isMulti {
            Button(String(
                localized: "contextMenu.showWorkspaceInFinder",
                defaultValue: "Show in Finder",
                bundle: .main
            )) {
                actions.onShowInFinder()
            }
            .disabled(!data.canShowInFinder)
        }
    }
}
