public import Foundation

/// The window-focus seam: brings a workspace/surface to front and focuses it,
/// returning whether focus succeeded. The two methods correspond to the legacy
/// `openNotificationInContext` (a specific registered window) and
/// `openNotificationFallback` (the active window when the owning context is not
/// yet registered). Each performs, in order: select the sidebar tabs pane,
/// bring the window to front, then focus the tab from the notification.
///
/// The window mechanics (the concrete `NSWindow`, the sidebar-selection write,
/// `bringToFront`, `focusTabFromNotification`, optional scroll restoration,
/// and the `#if DEBUG` UI-test recorders woven through them) stay app-side behind this seam so the package
/// carries no AppKit, `#if DEBUG`, or Combine. The coordinator only decides
/// *which* route to take and *what* to mark read on success.
@MainActor
public protocol NotificationOpenRouting: AnyObject {
    /// Focus `tabId`/`surfaceId`, resolving the owning registered window and
    /// falling back to the active window when none owns it. Returns whether
    /// focus succeeded. Mirrors the full `openNotification(tabId:surfaceId:notificationId:)`
    /// routing, including its `#if DEBUG` UI-test recorders, which the coordinator
    /// must not duplicate.
    func openRouted(tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool

    /// Focus `tabId`/`surfaceId` in the specific registered window `windowId`,
    /// used by the workspace-unread jump which targets one ordered window at a
    /// time. Returns whether focus succeeded. Mirrors `openNotificationInContext`.
    func openInWindow(
        windowId: UUID,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID?,
        notificationId: UUID?,
        scrollRow: Int?
    ) -> Bool

    /// Focus `tabId`/`surfaceId` in the active window when no registered context
    /// owns it. Returns whether focus succeeded. Mirrors `openNotificationFallback`.
    func openInActiveWindowFallback(tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool

    /// The workspace's title, resolved from whichever window owns it, falling
    /// back to the active tab manager. Mirrors `tabTitle(for:)`.
    func tabTitle(forTabId tabId: UUID) -> String?
}
