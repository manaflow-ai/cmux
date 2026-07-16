import AppKit
import Foundation

/// AppKit port of the workspace-group header's two SwiftUI context menus in
/// `Sources/SidebarWorkspaceGroupHeaderView.swift`:
/// - `makeMenu` mirrors the header row's right-click `.contextMenu`.
/// - `makePlusButtonMenu` mirrors the plus button's `.contextMenu` (New
///   Workspace in Group, resolved cwd config items, Edit Group Config…, Open
///   Workspace Groups Docs).
///
/// Item order, separators, disabled conditions, and localization keys match
/// the SwiftUI menus one-to-one. Built fresh per open from the immutable
/// group-row snapshot plus closure actions.
@MainActor
enum SidebarWorkspaceGroupHeaderContextMenuFactory {
    static func makeMenu(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        actions: SidebarWorkspaceGroupHeaderActions
    ) -> NSMenu {
        let menu = SidebarWorkspaceMenuItemBuilders.makeMenu()

        menu.addItem(newWorkspaceInGroupItem(actions: actions))

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.rename",
                defaultValue: "Rename Group..."
            )
        ) {
            actions.onRename()
        })

        let pinTitle = snapshot.isPinned
            ? String(
                localized: "workspaceGroup.contextMenu.unpin",
                defaultValue: "Unpin Group"
            )
            : String(
                localized: "workspaceGroup.contextMenu.pin",
                defaultValue: "Pin Group"
            )
        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(title: pinTitle) {
            actions.onTogglePinned()
        })

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.markRead",
                defaultValue: "Mark Group as Read"
            ),
            enabled: snapshot.canMarkRead
        ) {
            actions.onMarkRead()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.markUnread",
                defaultValue: "Mark Group as Unread"
            ),
            enabled: snapshot.canMarkUnread
        ) {
            actions.onMarkUnread()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.clearLatestNotifications",
                defaultValue: "Clear Latest Notifications"
            ),
            enabled: snapshot.hasLatestNotifications
        ) {
            actions.onClearLatestNotifications()
        })

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.markAllRead",
                defaultValue: "Mark All Workspaces in Group as Read"
            ),
            enabled: snapshot.canMarkAllRead
        ) {
            actions.onMarkAllRead()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.markAllUnread",
                defaultValue: "Mark All Workspaces in Group as Unread"
            ),
            enabled: snapshot.canMarkAllUnread
        ) {
            actions.onMarkAllUnread()
        })

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.editConfig",
                defaultValue: "Edit Group Config..."
            )
        ) {
            actions.onEditConfig()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.openDocs",
                defaultValue: "Open Workspace Groups Docs"
            )
        ) {
            actions.onOpenDocs()
        })

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.ungroup",
                defaultValue: "Ungroup Workspaces"
            )
        ) {
            actions.onUngroup()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.destructiveActionItem(
            title: String(
                localized: "workspaceGroup.contextMenu.delete",
                defaultValue: "Delete Group"
            )
        ) {
            actions.onDelete()
        })

        return menu
    }

    static func makePlusButtonMenu(
        snapshot: SidebarWorkspaceGroupRowSnapshot,
        actions: SidebarWorkspaceGroupHeaderActions
    ) -> NSMenu {
        let menu = SidebarWorkspaceMenuItemBuilders.makeMenu()

        menu.addItem(newWorkspaceInGroupItem(actions: actions))

        if !snapshot.cwdContextMenuItems.isEmpty {
            menu.addItem(.separator())
            for item in snapshot.cwdContextMenuItems {
                switch item {
                case .separator:
                    menu.addItem(.separator())
                case .action(let action):
                    menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(title: action.title) {
                        actions.onRunResolvedItem(action)
                    })
                }
            }
        }

        menu.addItem(.separator())

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.plus.contextMenu.editConfig",
                defaultValue: "Edit Group Config..."
            )
        ) {
            actions.onEditConfig()
        })

        menu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.plus.contextMenu.openDocs",
                defaultValue: "Open Workspace Groups Docs"
            )
        ) {
            actions.onOpenDocs()
        })

        return menu
    }

    private static func newWorkspaceInGroupItem(
        actions: SidebarWorkspaceGroupHeaderActions
    ) -> NSMenuItem {
        SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(
                localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                defaultValue: "New Workspace in Group"
            )
        ) {
            actions.onTapPlus()
        }
    }
}
