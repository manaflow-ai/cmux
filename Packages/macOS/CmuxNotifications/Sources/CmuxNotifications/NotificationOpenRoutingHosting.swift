public import Foundation

/// The window-mechanics seam driven by ``NotificationOpenRoutingCoordinator``.
///
/// The coordinator owns only the open-routing *decision skeleton* lifted from
/// `AppDelegate`'s `openNotification` / `openNotificationInContext` /
/// `openNotificationFallback` trio: try the owning registered window context,
/// else fall back to the active window; in each route select the sidebar tabs
/// pane, bring the window to front, focus the tab, and mark the notification
/// read on success. Every concrete effect, the live `NSWindow` resolution, the
/// sidebar-selection write, `bringToFront`, `TabManager.focusTabFromNotification`,
/// and the `notificationStore.markRead`, stays app-side behind this seam so the
/// package carries no AppKit and no `#if DEBUG`.
///
/// Tokens are opaque `AnyObject`s minted by the app side and handed straight
/// back, mirroring the established `preferredWindowToken: AnyObject?` pattern.
/// A *context token* identifies the registered main window that owns the tab
/// (resolved once, in ``contextToken(forTabId:)``, then reused for every
/// in-context primitive so the routing reads a single context, exactly as the
/// legacy body did). A *window token* is the resolved live `NSWindow` for a
/// route; the coordinator treats `nil` as "no realized window" and bails to the
/// same failure path the legacy guards took.
@MainActor
public protocol NotificationOpenRoutingHosting: AnyObject {
    /// The opaque context token for the registered main window that owns
    /// `tabId`, or `nil` when no registered context owns it (the fallback
    /// route). Mirrors `AppDelegate.contextContainingTabId(_:)`, resolving once.
    func contextToken(forTabId tabId: UUID) -> AnyObject?

    /// The resolved live `NSWindow` token for `contextToken`'s window, or `nil`
    /// when the window is not currently realized. Mirrors
    /// `context.window ?? NSApp.windows.first(where: identifier == expected)`.
    func contextWindowToken(forContextToken contextToken: AnyObject) -> AnyObject?

    /// Selects the tabs pane on `contextToken`'s per-window sidebar selection.
    /// Mirrors `sidebarSelectionState(for: context).selection = .tabs`.
    func selectSidebarTabs(forContextToken contextToken: AnyObject)

    /// Focuses `tabId`/`surfaceId` in `contextToken`'s tab manager, returning
    /// whether focus succeeded. Mirrors
    /// `context.tabManager.focusTabFromNotification(tabId, surfaceId:)`.
    func focusTabFromNotification(
        forContextToken contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?
    ) -> Bool

    /// Whether an active (global) tab manager exists for the fallback route.
    /// Mirrors the `guard let tabManager` gate.
    var hasActiveTabManager: Bool { get }

    /// Whether the active tab manager owns `tabId`. Mirrors
    /// `tabManager.tabs.contains(where: { $0.id == tabId })`.
    func activeTabManagerContains(tabId: UUID) -> Bool

    /// The resolved live `NSWindow` token for the fallback route, the key window
    /// or the first main terminal window, or `nil` when none exists. Mirrors
    /// `NSApp.keyWindow ?? NSApp.windows.first(where: isMainTerminalWindow)`.
    func keyOrMainTerminalWindowToken() -> AnyObject?

    /// Selects the tabs pane on the active (global) sidebar selection. Mirrors
    /// `sidebarSelectionState?.selection = .tabs`.
    func selectActiveSidebarTabs()

    /// Focuses `tabId`/`surfaceId` in the active tab manager, returning whether
    /// focus succeeded. Mirrors `tabManager.focusTabFromNotification(...)`.
    func focusTabInActiveTabManager(tabId: UUID, surfaceId: UUID?) -> Bool

    /// Brings `windowToken` to front. Mirrors `bringToFront(window)`.
    func bringWindowToFront(_ windowToken: AnyObject)

    /// Marks `notificationId` read when both it and the store are present.
    /// Mirrors `if let notificationId, let store = notificationStore { store.markRead(id:) }`.
    func markNotificationRead(notificationId: UUID?)
}
