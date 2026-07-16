import AppKit
import CmuxWorkspaces
import Foundation

/// AppKit port of the sidebar workspace row's SwiftUI context menu
/// (`TabItemView.workspaceContextMenu` in
/// `Sources/TabItemView+WorkspaceContextMenu.swift`, plus its group, todo, and
/// notifications sections). Item order, separators, disabled conditions,
/// singular/plural titles, localization keys, and keyboard equivalents match
/// the SwiftUI menu one-to-one.
///
/// Built fresh per open from an immutable snapshot plus closure actions; no
/// observable model is referenced and nothing is cached.
@MainActor
enum SidebarWorkspaceRowContextMenuFactory {
    static func makeMenu(
        snapshot: SidebarWorkspaceRowSnapshot,
        actions: SidebarWorkspaceRowActions
    ) -> NSMenu {
        let menu = SidebarWorkspaceMenuItemBuilders.makeMenu()
        let context = snapshot.contextMenu
        let targetIds = context.targetWorkspaceIds
        let isMulti = targetIds.count > 1

        addPinItem(to: menu, snapshot: snapshot, context: context, isMulti: isMulti, actions: actions)
        addGroupSection(to: menu, context: context, isMulti: isMulti, actions: actions)

        menu.addItem(.separator())

        addTodoSection(to: menu, context: context, targetIds: targetIds, isMulti: isMulti, actions: actions)

        menu.addItem(.separator())

        addRenameAndDescriptionItems(to: menu, snapshot: snapshot, isMulti: isMulti, actions: actions)
        addRemoteSection(to: menu, context: context, isMulti: isMulti, actions: actions)

        menu.addItem(SidebarWorkspaceRowContextMenuSubmenus.colorSubmenuItem(
            snapshot: snapshot,
            targetIds: targetIds,
            actions: actions
        ))

        if let copyableSidebarSSHError = snapshot.workspace.copyableSidebarSSHError {
            menu.addItem(.separator())
            menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: String(localized: "contextMenu.copySshError", defaultValue: "Copy SSH Error")
            ) {
                WorkspaceSurfaceIdentifierClipboardText.copy(copyableSidebarSSHError)
            })
        }

        menu.addItem(.separator())

        addReorderItems(to: menu, snapshot: snapshot, targetIds: targetIds, actions: actions)
        menu.addItem(SidebarWorkspaceRowContextMenuSubmenus.moveToWindowSubmenuItem(
            targetIds: targetIds,
            actions: actions
        ))

        menu.addItem(.separator())

        addCloseItems(to: menu, snapshot: snapshot, targetIds: targetIds, isMulti: isMulti, actions: actions)

        menu.addItem(.separator())

        addReadStateItems(to: menu, context: context, targetIds: targetIds, isMulti: isMulti, actions: actions)
        menu.addItem(SidebarWorkspaceRowContextMenuSubmenus.notificationsSubmenuItem(
            notifications: context.notifications,
            targetIds: targetIds,
            actions: actions
        ))

        menu.addItem(.separator())

        addCopyAndFinderItems(to: menu, snapshot: snapshot, targetIds: targetIds, isMulti: isMulti, actions: actions)

        return menu
    }

    // MARK: - Labels

    private static func label(multi: String, single: String, isMulti: Bool) -> String {
        isMulti ? multi : single
    }

    // MARK: - Pin

    private static func addPinItem(
        to menu: NSMenu,
        snapshot: SidebarWorkspaceRowSnapshot,
        context: SidebarWorkspaceContextMenuSnapshot,
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        let shouldPin = context.pinState?.pinned ?? !snapshot.workspace.isPinned
        let pinLabel = shouldPin
            ? label(
                multi: String(localized: "contextMenu.pinWorkspaces", defaultValue: "Pin Workspaces"),
                single: String(localized: "contextMenu.pinWorkspace", defaultValue: "Pin Workspace"),
                isMulti: isMulti)
            : label(
                multi: String(localized: "contextMenu.unpinWorkspaces", defaultValue: "Unpin Workspaces"),
                single: String(localized: "contextMenu.unpinWorkspace", defaultValue: "Unpin Workspace"),
                isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: pinLabel,
            enabled: context.pinState != nil
        ) {
            actions.performPin()
        })
    }

    // MARK: - Workspace groups

    /// Port of `TabItemView.workspaceGroupContextMenuSection(targetIds:isMulti:)`.
    private static func addGroupSection(
        to menu: NSMenu,
        context: SidebarWorkspaceContextMenuSnapshot,
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "contextMenu.workspaceGroup.newEmpty",
                defaultValue: "New Empty Workspace Group"
            ),
            enabled: context.canCreateEmptyGroup,
            shortcut: KeyboardShortcutSettings.shortcut(for: .newWorkspaceGroup)
        ) {
            actions.createEmptyGroup()
        })

        let eligibleTargetIds = context.eligibleGroupTargetIds
        guard !eligibleTargetIds.isEmpty else { return }

        let groups = context.groupMenuSnapshot.items
        let moveToGroupMenuState = WorkspaceGroupMoveToMenuState(groups: groups)
        let allTargetsInSameGroup = context.allEligibleTargetsGroupId

        let groupSelectedLabel = isMulti
            ? String(
                localized: "contextMenu.workspaceGroup.newFromSelection",
                defaultValue: "New Group from Selection"
            )
            : String(
                localized: "contextMenu.workspaceGroup.newFromWorkspace",
                defaultValue: "New Group from Workspace"
            )
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: groupSelectedLabel,
            shortcut: KeyboardShortcutSettings.shortcut(for: .groupSelectedWorkspaces)
        ) {
            // Port of `TabItemView.promptNewWorkspaceGroup(workspaceIds:)`.
            guard !eligibleTargetIds.isEmpty else { return }
            actions.createGroup(eligibleTargetIds)
        })

        let moveToGroupLabel = String(
            localized: "contextMenu.workspaceGroup.moveTo",
            defaultValue: "Move to Group"
        )
        if moveToGroupMenuState.rendersSubmenu {
            let submenu = SidebarWorkspaceMenuItemBuilders.makeMenu()
            for group in groups {
                let groupId = group.id
                submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                    title: group.name,
                    enabled: allTargetsInSameGroup != groupId
                ) {
                    actions.addTargetsToGroup(eligibleTargetIds, groupId)
                })
            }
            menu.addItem(SidebarWorkspaceMenuItemBuilders.submenuItem(
                title: moveToGroupLabel,
                submenu: submenu
            ))
        } else {
            menu.addItem(SidebarWorkspaceMenuItemBuilders.disabledItem(title: moveToGroupLabel))
        }

        if context.hasGroupedEligibleTarget {
            menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: String(
                    localized: "contextMenu.workspaceGroup.remove",
                    defaultValue: "Remove from Group"
                )
            ) {
                actions.removeTargetsFromGroup(eligibleTargetIds)
            })
        }
    }

    // MARK: - Todo

    /// Port of `TabItemView.workspaceTodoContextMenuSection`.
    private static func addTodoSection(
        to menu: NSMenu,
        context: SidebarWorkspaceContextMenuSnapshot,
        targetIds: [UUID],
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        menu.addItem(SidebarWorkspaceRowContextMenuSubmenus.statusSubmenuItem(
            lanes: context.todoStatusLanes,
            targetIds: targetIds,
            actions: actions
        ))

        let markDoneLabel = isMulti
            ? String(localized: "contextMenu.markWorkspacesDone", defaultValue: "Mark Workspaces as Done")
            : String(localized: "contextMenu.markWorkspaceDone", defaultValue: "Mark Workspace as Done")
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: markDoneLabel,
            shortcut: KeyboardShortcutSettings.shortcut(for: .markWorkspaceDone)
        ) {
            actions.applyTodoStatus(.done, targetIds)
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.addChecklistItem", defaultValue: "Add Checklist Item…")
        ) {
            actions.requestChecklistAdd()
        })
    }

    // MARK: - Rename and description

    private static func addRenameAndDescriptionItems(
        to menu: NSMenu,
        snapshot: SidebarWorkspaceRowSnapshot,
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.renameWorkspace", defaultValue: "Rename Workspace…"),
            shortcut: KeyboardShortcutSettings.shortcut(for: .renameWorkspace)
        ) {
            SidebarWorkspaceMenuPrompts.promptRename(snapshot: snapshot, actions: actions)
        })

        if snapshot.hasCustomTitle {
            menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: String(localized: "contextMenu.removeCustomWorkspaceName", defaultValue: "Remove Custom Workspace Name")
            ) {
                actions.clearCustomTitle()
            })
        }

        guard !isMulti else { return }

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.editWorkspaceDescription", defaultValue: "Edit Workspace Description…"),
            shortcut: KeyboardShortcutSettings.shortcut(for: .editWorkspaceDescription)
        ) {
            actions.editDescription()
        })

        if snapshot.hasCustomDescription {
            menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: String(localized: "contextMenu.clearWorkspaceDescription", defaultValue: "Clear Workspace Description")
            ) {
                actions.clearCustomDescription()
            })
        }
    }

    // MARK: - Remote connect

    private static func addRemoteSection(
        to menu: NSMenu,
        context: SidebarWorkspaceContextMenuSnapshot,
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        let remoteTargetIds = context.remoteTargetWorkspaceIds
        guard !remoteTargetIds.isEmpty else { return }

        menu.addItem(.separator())

        let reconnectLabel = label(
            multi: String(localized: "contextMenu.reconnectWorkspaces", defaultValue: "Reconnect Workspaces"),
            single: String(localized: "contextMenu.reconnectWorkspace", defaultValue: "Reconnect Workspace"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: reconnectLabel,
            enabled: !context.allRemoteTargetsConnecting
        ) {
            actions.reconnectTargets(remoteTargetIds)
        })

        let disconnectLabel = label(
            multi: String(localized: "contextMenu.disconnectWorkspaces", defaultValue: "Disconnect Workspaces"),
            single: String(localized: "contextMenu.disconnectWorkspace", defaultValue: "Disconnect Workspace"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: disconnectLabel,
            enabled: !context.allRemoteTargetsDisconnected
        ) {
            actions.disconnectTargets(remoteTargetIds)
        })
    }

    // MARK: - Reorder

    private static func addReorderItems(
        to menu: NSMenu,
        snapshot: SidebarWorkspaceRowSnapshot,
        targetIds: [UUID],
        actions: SidebarWorkspaceRowActions
    ) {
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.moveUp", defaultValue: "Move Up"),
            enabled: snapshot.index != 0
        ) {
            actions.moveBy(-1)
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.moveDown", defaultValue: "Move Down"),
            enabled: snapshot.index < snapshot.workspaceCount - 1
        ) {
            actions.moveBy(1)
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.moveToTop", defaultValue: "Move to Top"),
            enabled: !targetIds.isEmpty
        ) {
            actions.moveTargetsToTop(targetIds)
        })
    }

    // MARK: - Close

    private static func addCloseItems(
        to menu: NSMenu,
        snapshot: SidebarWorkspaceRowSnapshot,
        targetIds: [UUID],
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        let closeLabel = label(
            multi: String(localized: "contextMenu.closeWorkspaces", defaultValue: "Close Workspaces"),
            single: String(localized: "contextMenu.closeWorkspace", defaultValue: "Close Workspace"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: closeLabel,
            enabled: !targetIds.isEmpty,
            shortcut: KeyboardShortcutSettings.shortcut(for: .closeWorkspace)
        ) {
            actions.closeTargets(targetIds, true)
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.closeOtherWorkspaces", defaultValue: "Close Other Workspaces"),
            enabled: !(snapshot.workspaceCount <= 1 || targetIds.count == snapshot.workspaceCount)
        ) {
            actions.closeOtherTargets(targetIds)
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.closeWorkspacesBelow", defaultValue: "Close Workspaces Below"),
            enabled: snapshot.index < snapshot.workspaceCount - 1
        ) {
            actions.closeTargetsBelow()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.closeWorkspacesAbove", defaultValue: "Close Workspaces Above"),
            enabled: snapshot.index != 0
        ) {
            actions.closeTargetsAbove()
        })
    }

    // MARK: - Read state

    private static func addReadStateItems(
        to menu: NSMenu,
        context: SidebarWorkspaceContextMenuSnapshot,
        targetIds: [UUID],
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        let markReadLabel = label(
            multi: String(localized: "contextMenu.markWorkspacesRead", defaultValue: "Mark Workspaces as Read"),
            single: String(localized: "contextMenu.markWorkspaceRead", defaultValue: "Mark Workspace as Read"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: markReadLabel,
            enabled: context.canMarkRead
        ) {
            actions.markRead(targetIds)
        })

        let markUnreadLabel = label(
            multi: String(localized: "contextMenu.markWorkspacesUnread", defaultValue: "Mark Workspaces as Unread"),
            single: String(localized: "contextMenu.markWorkspaceUnread", defaultValue: "Mark Workspace as Unread"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: markUnreadLabel,
            enabled: context.canMarkUnread
        ) {
            actions.markUnread(targetIds)
        })

        let clearLatestNotificationLabel = label(
            multi: String(localized: "contextMenu.clearLatestNotifications", defaultValue: "Clear Latest Notifications"),
            single: String(localized: "contextMenu.clearLatestNotification", defaultValue: "Clear Latest Notification"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: clearLatestNotificationLabel,
            enabled: context.hasLatestNotification
        ) {
            actions.clearLatestNotifications(targetIds)
        })
    }

    // MARK: - Copy and Finder

    private static func addCopyAndFinderItems(
        to menu: NSMenu,
        snapshot: SidebarWorkspaceRowSnapshot,
        targetIds: [UUID],
        isMulti: Bool,
        actions: SidebarWorkspaceRowActions
    ) {
        let copyWorkspaceIDLabel = label(
            multi: String(localized: "contextMenu.copyWorkspaceIDs", defaultValue: "Copy Workspace IDs"),
            single: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: copyWorkspaceIDLabel,
            enabled: !targetIds.isEmpty
        ) {
            WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(targetIds, includeRefs: false)
        })

        let copyWorkspaceLinkLabel = label(
            multi: String(localized: "contextMenu.copyWorkspaceLinks", defaultValue: "Copy Workspace Links"),
            single: String(localized: "contextMenu.copyWorkspaceLink", defaultValue: "Copy Workspace Link"),
            isMulti: isMulti)
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: copyWorkspaceLinkLabel,
            enabled: !targetIds.isEmpty
        ) {
            actions.copyWorkspaceLinks(targetIds)
        })

        guard !isMulti else { return }

        let finderDirectoryPath = snapshot.workspace.finderDirectoryPath
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.showWorkspaceInFinder", defaultValue: "Show in Finder"),
            enabled: finderDirectoryPath != nil
        ) {
            let url = finderDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            Task { @MainActor in
                await WorkspaceFinderDirectoryOpener.openInFinder(url)
            }
        })
    }
}
