public import Foundation

/// A notification reduced to the fields the navigation coordinator needs to
/// decide whether and where to open it: identity, its owning workspace/surface,
/// read state, and whether it carries a click action (which routes to a
/// side-effect like reveal-in-Finder instead of focusing a terminal surface).
///
/// The concrete `TerminalNotification` lives in the app target; the coordinator
/// only ever sees this value snapshot so it stays free of app-target types.
public struct NotificationNavSnapshot: Sendable, Equatable, Identifiable {
    /// The notification's stable identity.
    public let id: UUID
    /// The id of the workspace (tab) that owns the notification.
    public let tabId: UUID
    /// The id of the surface within the workspace, when the notification is
    /// scoped to a specific surface rather than the workspace as a whole.
    public let surfaceId: UUID?
    /// Whether the notification has already been read.
    public let isRead: Bool
    /// The notification's click action, if any. When present the notification
    /// opens via ``NotificationClickRouting`` (a side effect such as revealing a
    /// path in Finder) rather than focusing a terminal surface.
    public let clickAction: NotificationNavClickAction?

    /// Creates a navigation snapshot of a notification.
    public init(
        id: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        isRead: Bool,
        clickAction: NotificationNavClickAction?
    ) {
        self.id = id
        self.tabId = tabId
        self.surfaceId = surfaceId
        self.isRead = isRead
        self.clickAction = clickAction
    }

    /// Whether the notification carries a click action.
    public var hasClickAction: Bool { clickAction != nil }

    /// Mirrors the legacy `shouldOpenFromJumpToLatestUnread` predicate: an
    /// unread notification with no click action that is not excluded by id or
    /// by owning workspace. (Click-action notifications are opened directly via
    /// ``NotificationNavigationCoordinator/openNotification(_:)``, never via the
    /// jump-to-latest scan, matching the original behavior.)
    public func isOpenableForJump(
        excludingNotificationId excludedNotificationId: UUID?,
        excludingWorkspaceId excludedWorkspaceId: UUID?
    ) -> Bool {
        guard !isRead, id != excludedNotificationId else { return false }
        if let excludedWorkspaceId, tabId == excludedWorkspaceId {
            return false
        }
        return !hasClickAction
    }
}
