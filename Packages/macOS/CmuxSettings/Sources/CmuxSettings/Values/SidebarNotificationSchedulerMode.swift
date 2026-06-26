import Foundation

/// Automatic policy for ordering unread-notification workspaces in the sidebar.
public enum SidebarNotificationSchedulerMode: String, CaseIterable, Sendable, SettingCodable {
    case smartUrgency
    case blockedFirst
    case smallWins
    case aging
    case roundRobin
    case arrivalOrder
}
