import AppKit
import SwiftUI

/// Menu-open-deferred wrapper for a sidebar row's workspace context menu.
/// `contextMenu(menuItems:)` evaluates its content closure during every row
/// body evaluation, so building the menu inline made each visible row resolve
/// ~12 localized labels, keyboard-shortcut lookups, and the window-move target
/// list on every render pass. Constructing this wrapper is a struct copy;
/// `workspaceContextMenu` runs only when SwiftUI realizes the menu content.
struct TabItemWorkspaceContextMenuContent: View {
    let row: TabItemView

    var body: some View {
        row.workspaceContextMenu
    }
}

extension TabItemView {
    private func contextMenuLabel(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    @ViewBuilder
    var workspaceContextMenu: some View {
        let workspaceSnapshot = self.workspaceSnapshot
        let context = snapshot.contextMenu
        let targetIds = context.targetWorkspaceIds
        let isMulti = targetIds.count > 1
        let shouldPin = context.pinState?.pinned ?? !workspaceSnapshot.isPinned
        let reconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        let disconnectLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        let pinLabel = shouldPin
            ? contextMenuLabel(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : contextMenuLabel(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        let closeLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        let markReadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        let markUnreadLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        let clearLatestNotificationLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        let copyWorkspaceIDLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        let copyWorkspaceLinkLabel = contextMenuLabel(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        let renameWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        let editWorkspaceDescriptionShortcut = KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        let closeWorkspaceShortcut = KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        let windowMoveTargets = actions.currentWindowMoveTargets()
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")

        Button(pinLabel) {
            actions.performPin()
        }
        .disabled(context.pinState == nil)

        workspaceGroupContextMenuSection(targetIds: targetIds, isMulti: isMulti)

        Divider()

        workspaceTodoContextMenuSection

        Divider()

        if let key = renameWorkspaceShortcut.keyEquivalent {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
            .keyboardShortcut(key, modifiers: renameWorkspaceShortcut.eventModifiers)
        } else {
            Button(String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…")) {
                promptRename()
            }
        }

        if snapshot.hasCustomTitle {
            Button(String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")) {
                actions.clearCustomTitle()
            }
        }

        if !isMulti {
            if let key = editWorkspaceDescriptionShortcut.keyEquivalent {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
                .keyboardShortcut(key, modifiers: editWorkspaceDescriptionShortcut.eventModifiers)
            } else {
                Button(String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…")) {
                    beginWorkspaceDescriptionEditFromContextMenu()
                }
            }

            if snapshot.hasCustomDescription {
                Button(String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")) {
                    actions.clearCustomDescription()
                }
            }
        }

        if !context.remoteTargetWorkspaceIds.isEmpty {
            Divider()

            Button(reconnectLabel) {
                actions.reconnectTargets(context.remoteTargetWorkspaceIds)
            }
            .disabled(context.allRemoteTargetsConnecting)

            Button(disconnectLabel) {
                actions.disconnectTargets(context.remoteTargetWorkspaceIds)
            }
            .disabled(context.allRemoteTargetsDisconnected)
        }

        Menu(String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color")) {
            let tabColorPalette = WorkspaceTabColorSettings.palette()

            if workspaceSnapshot.customColorHex != nil {
                Button {
                    applyTabColor(nil, targetIds: targetIds)
                } label: {
                    Label(String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"), systemImage: "xmark.circle")
                }
            }

            Button {
                promptCustomColor(targetIds: targetIds)
            } label: {
                Label(String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"), systemImage: "paintpalette")
            }

            if !tabColorPalette.isEmpty {
                Divider()
            }

            ForEach(tabColorPalette, id: \.id) { entry in
                Button {
                    applyTabColor(entry.hex, targetIds: targetIds)
                } label: {
                    Label {
                        Text(entry.name)
                    } icon: {
                        Image(nsImage: coloredCircleImage(color: tabColorSwatchColor(for: entry.hex)))
                    }
                }
            }
        }

        if let copyableSidebarSSHError = workspaceSnapshot.copyableSidebarSSHError {
            Divider()

            Button(String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")) {
                WorkspaceSurfaceIdentifierClipboardText.copy(copyableSidebarSSHError)
            }
        }

        Divider()

        Button(String(localized: "contextMenu.moveUp", defaultValue: "Move Up")) {
            moveBy(-1)
        }
        .disabled(index == 0)

        Button(String(localized: "contextMenu.moveDown", defaultValue: "Move Down")) {
            moveBy(1)
        }
        .disabled(index >= snapshot.workspaceCount - 1)

        Button(String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top")) {
            actions.moveTargetsToTop(targetIds)
        }
        .disabled(targetIds.isEmpty)

        Menu(moveMenuTitle) {
            Button(String(localized: "contextMenu.newWindow", defaultValue: "New Window")) {
                actions.moveTargetsToNewWindow(targetIds)
            }
            .disabled(targetIds.isEmpty)

            if !windowMoveTargets.isEmpty {
                Divider()
            }

            ForEach(windowMoveTargets) { target in
                Button(target.label) {
                    actions.moveTargetsToWindow(targetIds, target.windowId)
                }
                .disabled(target.isCurrentWindow || targetIds.isEmpty)
            }
        }
        .disabled(targetIds.isEmpty)

        Divider()

        if let key = closeWorkspaceShortcut.keyEquivalent {
            Button(closeLabel) {
                actions.closeTargets(targetIds, true)
            }
            .keyboardShortcut(key, modifiers: closeWorkspaceShortcut.eventModifiers)
            .disabled(targetIds.isEmpty)
        } else {
            Button(closeLabel) {
                actions.closeTargets(targetIds, true)
            }
            .disabled(targetIds.isEmpty)
        }

        Button(String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces")) {
            actions.closeOtherTargets(targetIds)
        }
        .disabled(snapshot.workspaceCount <= 1 || targetIds.count == snapshot.workspaceCount)

        Button(String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below")) {
            actions.closeTargetsBelow()
        }
        .disabled(index >= snapshot.workspaceCount - 1)

        Button(String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above")) {
            actions.closeTargetsAbove()
        }
        .disabled(index == 0)

        Divider()

        Button(markReadLabel) {
            actions.markRead(targetIds)
        }
        .disabled(!context.canMarkRead)

        Button(markUnreadLabel) {
            actions.markUnread(targetIds)
        }
        .disabled(!context.canMarkUnread)

        Button(clearLatestNotificationLabel) {
            actions.clearLatestNotifications(targetIds)
        }
        .disabled(!context.hasLatestNotification)

        workspaceNotificationsContextMenu(targetIds)
        Divider()
        Button(copyWorkspaceIDLabel) {
            copyWorkspaceIdsToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        Button(copyWorkspaceLinkLabel) {
            copyWorkspaceLinksToPasteboard(targetIds)
        }
        .disabled(targetIds.isEmpty)

        if !isMulti {
            Button(String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder")) {
                let url = workspaceSnapshot.finderDirectoryPath
                    .map { URL(fileURLWithPath: $0, isDirectory: true) }
                workspaceFinderDirectoryOpenRequest = WorkspaceFinderDirectoryOpenRequest(directoryURL: url)
            }
            .disabled(workspaceSnapshot.finderDirectoryPath == nil)
        }
    }
}
