import AppKit
import CmuxSettings
import CmuxWorkspaces
import Foundation

/// Submenu builders for the workspace-row context menu. Each mirrors one
/// SwiftUI `Menu { ... }` block:
/// - Status: `TabItemView.workspaceTodoContextMenuSection`
/// - Workspace Color: `TabItemView.workspaceContextMenu` color `Menu`
/// - Move to Window: `TabItemView.workspaceContextMenu` move `Menu`
/// - Notifications: `TabItemView.workspaceNotificationsContextMenu(_:)`
@MainActor
enum SidebarWorkspaceRowContextMenuSubmenus {
    // MARK: - Status lanes

    /// Lane rows with `.on` state on the selected lane; a separator after the
    /// Auto row (first lane, nil status, not None) and before the None row.
    static func statusSubmenuItem(
        lanes: [WorkspaceTodoStatusLane],
        targetIds: [UUID],
        actions: SidebarWorkspaceRowActions
    ) -> NSMenuItem {
        let submenu = SidebarWorkspaceMenuItemBuilders.makeMenu()
        for lane in lanes {
            // Divider before the None row (separates opt-out from lanes).
            if lane.isNone {
                submenu.addItem(.separator())
            }
            let laneStatus = lane.status
            let laneIsNone = lane.isNone
            submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: lane.title,
                state: lane.isSelected ? .on : .off
            ) {
                if laneIsNone {
                    actions.hideTodoStatus(targetIds)
                } else {
                    actions.applyTodoStatus(laneStatus, targetIds)
                }
            })
            // Divider after the Auto row (first lane, nil status, not None).
            if lane.status == nil, !lane.isNone {
                submenu.addItem(.separator())
            }
        }
        return SidebarWorkspaceMenuItemBuilders.submenuItem(
            title: String(localized: "contextMenu.workspaceStatus", defaultValue: "Status"),
            submenu: submenu
        )
    }

    // MARK: - Workspace color

    static func colorSubmenuItem(
        snapshot: SidebarWorkspaceRowSnapshot,
        targetIds: [UUID],
        actions: SidebarWorkspaceRowActions
    ) -> NSMenuItem {
        let submenu = SidebarWorkspaceMenuItemBuilders.makeMenu()
        let tabColorPalette = WorkspaceTabColorSettings.palette()
        let forceBright = snapshot.settings.activeTabIndicatorStyle == .leftRail

        if snapshot.workspace.customColorHex != nil {
            submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: String(localized: "contextMenu.clearColor", defaultValue: "Clear Color"),
                image: SidebarWorkspaceMenuItemBuilders.systemSymbolImage("xmark.circle")
            ) {
                actions.applyColor(nil, targetIds)
            })
        }

        submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.chooseCustomColor", defaultValue: "Choose Custom Color…"),
            image: SidebarWorkspaceMenuItemBuilders.systemSymbolImage("paintpalette")
        ) {
            SidebarWorkspaceMenuPrompts.promptCustomColor(
                snapshot: snapshot,
                actions: actions,
                targetIds: targetIds
            )
        })

        if !tabColorPalette.isEmpty {
            submenu.addItem(.separator())
        }

        for entry in tabColorPalette {
            let hex = entry.hex
            submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: entry.name,
                image: coloredCircleImage(
                    color: SidebarWorkspaceMenuItemBuilders.swatchColor(hex: hex, forceBright: forceBright)
                )
            ) {
                actions.applyColor(hex, targetIds)
            })
        }

        return SidebarWorkspaceMenuItemBuilders.submenuItem(
            title: String(localized: "contextMenu.workspaceColor", defaultValue: "Workspace Color"),
            submenu: submenu
        )
    }

    // MARK: - Move to window

    /// Window targets are resolved via `actions.currentWindowMoveTargets()` at
    /// menu build time (the controller builds a fresh menu per open), matching
    /// the SwiftUI menu's deferred-content evaluation.
    static func moveToWindowSubmenuItem(
        targetIds: [UUID],
        actions: SidebarWorkspaceRowActions
    ) -> NSMenuItem {
        let windowMoveTargets = actions.currentWindowMoveTargets()
        let moveMenuTitle = targetIds.count > 1
            ? String(localized: "contextMenu.moveWorkspacesToWindow", defaultValue: "Move Workspaces to Window")
            : String(localized: "contextMenu.moveWorkspaceToWindow", defaultValue: "Move Workspace to Window")

        let submenu = SidebarWorkspaceMenuItemBuilders.makeMenu()
        submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
            title: String(localized: "contextMenu.newWindow", defaultValue: "New Window"),
            enabled: !targetIds.isEmpty
        ) {
            actions.moveTargetsToNewWindow(targetIds)
        })

        if !windowMoveTargets.isEmpty {
            submenu.addItem(.separator())
        }

        for target in windowMoveTargets {
            let windowId = target.windowId
            submenu.addItem(SidebarWorkspaceMenuItemBuilders.actionItem(
                title: target.label,
                enabled: !(target.isCurrentWindow || targetIds.isEmpty)
            ) {
                actions.moveTargetsToWindow(targetIds, windowId)
            })
        }

        return SidebarWorkspaceMenuItemBuilders.submenuItem(
            title: moveMenuTitle,
            enabled: !targetIds.isEmpty,
            submenu: submenu
        )
    }

    // MARK: - Notifications

    static func notificationsSubmenuItem(
        notifications: [TerminalNotification],
        targetIds: [UUID],
        actions: SidebarWorkspaceRowActions
    ) -> NSMenuItem {
        let submenu = SidebarWorkspaceMenuItemBuilders.makeMenu()
        if notifications.isEmpty {
            submenu.addItem(SidebarWorkspaceMenuItemBuilders.disabledItem(
                title: String(localized: "contextMenu.notifications.empty", defaultValue: "No Notifications")
            ))
        } else {
            for notification in notifications {
                let title = notificationMenuTitle(notification)
                let item = SidebarWorkspaceMenuItemBuilders.actionItem(title: title) {
                    actions.openNotification(notification)
                }
                if title.contains("\n") {
                    // NSMenuItem renders multi-line titles only through an
                    // attributed title; the SwiftUI menu showed both lines.
                    item.attributedTitle = NSAttributedString(
                        string: title,
                        attributes: [.font: NSFont.menuFont(ofSize: 0)]
                    )
                }
                submenu.addItem(item)
            }
        }
        return SidebarWorkspaceMenuItemBuilders.submenuItem(
            title: String(localized: "contextMenu.notifications", defaultValue: "Notifications"),
            enabled: !targetIds.isEmpty,
            submenu: submenu
        )
    }

    /// Port of `TabItemView.workspaceNotificationMenuTitle(_:)`.
    private static func notificationMenuTitle(_ notification: TerminalNotification) -> String {
        let timeText = notification.createdAt.formatted(date: .abbreviated, time: .shortened)
        let title = notificationMenuText(notification.title, limit: 80)
        let detail = notificationMenuText(
            notification.body.isEmpty ? notification.subtitle : notification.body,
            limit: 120
        )
        let readPrefix = notification.isRead ? "" : "• "
        let firstLine = title.isEmpty
            ? "\(readPrefix)\(timeText)"
            : "\(readPrefix)\(timeText)  \(title)"
        guard !detail.isEmpty else { return firstLine }
        return "\(firstLine)\n\(detail)"
    }

    /// Port of `TabItemView.workspaceNotificationMenuText(_:limit:)`.
    private static func notificationMenuText(_ value: String, limit: Int) -> String {
        let firstLine = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let prefix = String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }
}
