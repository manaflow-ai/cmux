import Foundation

/// A localized notification-mute action shared by SwiftUI and AppKit menus.
enum NotificationMuteMenuOption {
    case muteWorkspace
    case muteWorkspaces
    case unmuteWorkspace
    case unmuteWorkspaces

    var title: String {
        switch self {
        case .muteWorkspace:
            String(
                localized: "contextMenu.muteWorkspaceNotifications",
                defaultValue: "Mute Workspace Notifications"
            )
        case .muteWorkspaces:
            String(
                localized: "contextMenu.muteWorkspacesNotifications",
                defaultValue: "Mute Notifications for Selected Workspaces"
            )
        case .unmuteWorkspace:
            String(
                localized: "contextMenu.unmuteWorkspaceNotifications",
                defaultValue: "Unmute Workspace Notifications"
            )
        case .unmuteWorkspaces:
            String(
                localized: "contextMenu.unmuteWorkspacesNotifications",
                defaultValue: "Unmute Notifications for Selected Workspaces"
            )
        }
    }
}
