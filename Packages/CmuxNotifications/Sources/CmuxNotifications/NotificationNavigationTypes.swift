public import Foundation

/// A notification reduced to the fields the navigation coordinator needs to
/// decide whether and where to open it: identity, its owning workspace/surface,
/// read state, and whether it carries a click action (which routes to a
/// side-effect like reveal-in-Finder instead of focusing a terminal surface).
///
/// The concrete `TerminalNotification` lives in the app target; the coordinator
/// only ever sees this value snapshot so it stays free of app-target types.
public struct NotificationNavSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let tabId: UUID
    public let surfaceId: UUID?
    public let isRead: Bool
    /// The notification's click action, if any. When present the notification
    /// opens via ``NotificationClickRouting`` (a side effect such as revealing a
    /// path in Finder) rather than focusing a terminal surface.
    public let clickAction: NotificationNavClickAction?

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

/// An opaque value handle for one registered main window, surfaced by
/// ``MainWindowContextResolving``. The coordinator never sees the concrete
/// `MainWindowContext` or `NSWindow`; it routes by `windowId` and consults the
/// workspace ids the window currently owns, exactly as the legacy
/// `context.tabManager.tabs` scan did.
public struct MainWindowTarget: Sendable, Equatable, Identifiable {
    public let windowId: UUID
    /// The ids of the workspaces this window currently owns, in the window's
    /// own tab order (mirrors `context.tabManager.tabs.map(\.id)`).
    public let workspaceIds: [UUID]

    public var id: UUID { windowId }

    public init(windowId: UUID, workspaceIds: [UUID]) {
        self.windowId = windowId
        self.workspaceIds = workspaceIds
    }
}

/// A notification click action the coordinator can dispatch without knowing
/// how it is performed. The single case mirrors the app-target
/// `TerminalNotificationClickAction`; the coordinator forwards it to
/// ``NotificationClickRouting`` and never performs the side effect itself.
public enum NotificationNavClickAction: Sendable, Equatable {
    case revealInFinder(path: String)
}
