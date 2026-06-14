public import Foundation
import Observation

/// Orchestrates notification jump/open navigation: which unread notification to
/// open, in which window, with what unread state cleared and what marked read.
/// Lifted verbatim from `AppDelegate`'s jump/open cluster
/// (`jumpToLatestUnread`, `openLatestWorkspaceUnread`, `openWorkspaceUnread`,
/// `clearWorkspaceUnreadAfterJump`, `openTerminalNotification`,
/// `openNotification`, `tabTitle`), with every app-target collaborator replaced
/// by an injected protocol seam.
///
/// A Coordinator (CONVENTIONS §2): it sequences a user flow and owns no I/O.
/// `@MainActor` because every navigation entry point is a MainActor UI path and
/// the seams it drives are themselves `@MainActor`. `@Observable` for parity
/// with the package's other navigation model and to allow future observable
/// navigation state, though this wave exposes none.
///
/// The focused-mark cluster (`toggleFocusedNotificationUnread`,
/// `markFocusedNotificationAsOldestUnread*`) is intentionally NOT lifted in this
/// wave: it reaches into ~12 `Workspace` unread predicates and the
/// first-responder `focusedTerminalShortcutContext`, which do not seam cleanly
/// without a wider workspace-unread protocol. It stays in `AppDelegate` (see the
/// wave-2 note on the PR).
@MainActor
@Observable
public final class NotificationNavigationCoordinator {
    private let store: any NotificationNavigationStoreReading
    private let windows: any MainWindowContextResolving
    private let unreadTargeting: any UnreadWorkspaceTargeting
    private let openRouting: any NotificationOpenRouting
    private let clickRouting: any NotificationClickRouting

    /// Signalled after a jump/open focuses a workspace/surface, so the app-target
    /// `#if DEBUG` jump-unread UI-test recorders (which observe Combine and
    /// first-responder events the package must not import) can arm/record. Carries
    /// the focused `(tabId, surfaceId?)`. No-op in production builds.
    public var onDidFocusForJumpUnread: ((UUID, UUID?) -> Void)?

    public init(
        store: any NotificationNavigationStoreReading,
        windows: any MainWindowContextResolving,
        unreadTargeting: any UnreadWorkspaceTargeting,
        openRouting: any NotificationOpenRouting,
        clickRouting: any NotificationClickRouting
    ) {
        self.store = store
        self.windows = windows
        self.unreadTargeting = unreadTargeting
        self.openRouting = openRouting
        self.clickRouting = clickRouting
    }

    // MARK: Jump

    /// Opens the latest openable unread notification, returning its id, or `nil`
    /// when nothing could be opened. Mirrors `AppDelegate.jumpToLatestUnread`.
    @discardableResult
    public func jumpToLatestUnread(
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> UUID? {
        for notification in store.orderedNotifications
        where notification.isOpenableForJump(
            excludingNotificationId: excludedNotificationId,
            excludingWorkspaceId: excludedWorkspaceId
        ) {
            if openNotification(notification) {
                return notification.id
            }
        }
        _ = openLatestWorkspaceUnread(excludingWorkspaceId: excludedWorkspaceId)
        return nil
    }

    private func openLatestWorkspaceUnread(excludingWorkspaceId excludedWorkspaceId: UUID? = nil) -> Bool {
        var unreadWorkspaceIds = store.workspaceUnreadIndicatorIds
        if let excludedWorkspaceId {
            unreadWorkspaceIds.remove(excludedWorkspaceId)
        }
        guard !unreadWorkspaceIds.isEmpty else { return false }

        for target in windows.orderedTargetsForUnreadJump {
            for workspaceId in target.workspaceIds where unreadWorkspaceIds.contains(workspaceId) {
                if openWorkspaceUnread(workspaceId: workspaceId, in: target) {
                    return true
                }
            }
        }

        // The legacy fallback used the active tab manager's first unread
        // workspace; `orderedTargetsForUnreadJump` already encodes that ordering
        // (the active manager's window sorts first), so the first unread id
        // across all targets matches `tabManager.tabs.first(where:)`.
        guard let workspaceId = windows.orderedTargetsForUnreadJump
            .lazy
            .flatMap(\.workspaceIds)
            .first(where: { unreadWorkspaceIds.contains($0) }) else {
            return false
        }
        let panelId = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: workspaceId)
        let didOpen = openRouting.openInActiveWindowFallback(
            tabId: workspaceId,
            surfaceId: panelId,
            notificationId: nil
        )
        if didOpen {
            signalDidFocusForJumpUnread(tabId: workspaceId, surfaceId: panelId)
            clearWorkspaceUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
        }
        return didOpen
    }

    private func openWorkspaceUnread(workspaceId: UUID, in target: MainWindowTarget) -> Bool {
        let panelId = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: workspaceId)
        let didOpen = openRouting.openInWindow(
            windowId: target.windowId,
            tabId: workspaceId,
            surfaceId: panelId,
            notificationId: nil
        )
        if didOpen {
            signalDidFocusForJumpUnread(tabId: workspaceId, surfaceId: panelId)
            clearWorkspaceUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
        }
        return didOpen
    }

    private func clearWorkspaceUnreadAfterJump(workspaceId: UUID, panelId: UUID?) {
        if let panelId,
           unreadTargeting.shouldTriggerManualUnreadJumpFlash(workspaceId: workspaceId, panelId: panelId) {
            unreadTargeting.triggerUnreadIndicatorDismissFlash(workspaceId: workspaceId, panelId: panelId)
        }
        unreadTargeting.clearUnreadAfterJump(workspaceId: workspaceId, panelId: panelId)
    }

    // MARK: Open

    /// Opens a single notification, returning whether it opened. Click-action
    /// notifications run their side effect; the rest focus their surface.
    /// Mirrors `AppDelegate.openTerminalNotification`.
    @discardableResult
    public func openNotification(_ notification: NotificationNavSnapshot) -> Bool {
        if notification.hasClickAction {
            // A click action exists; resolve and perform it via the router.
            // The router returns `false` when the action cannot be resolved or
            // performed, matching the legacy `performTerminalNotificationClickAction`.
            return openNotificationViaClickRouting(notification)
        }
        return open(
            tabId: notification.tabId,
            surfaceId: notification.surfaceId,
            notificationId: notification.id
        )
    }

    private func openNotificationViaClickRouting(_ notification: NotificationNavSnapshot) -> Bool {
        guard let action = notification.clickAction else { return false }
        let didPerform = clickRouting.perform(action)
        if didPerform {
            store.markRead(id: notification.id)
        }
        return didPerform
    }

    /// Focuses `tabId`/`surfaceId`, marking `notificationId` read on success.
    /// Routes to the owning registered window, falling back to the active window
    /// when no context owns the tab. Mirrors `AppDelegate.openNotification`
    /// (the routing decision and its `#if DEBUG` recorders live behind the seam).
    @discardableResult
    public func open(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        openRouting.openRouted(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
    }

    // MARK: Titles

    /// The workspace's title. Mirrors `AppDelegate.tabTitle(for:)`.
    public func tabTitle(forTabId tabId: UUID) -> String? {
        openRouting.tabTitle(forTabId: tabId)
    }

    // MARK: Helpers

    private func signalDidFocusForJumpUnread(tabId: UUID, surfaceId: UUID?) {
        onDidFocusForJumpUnread?(tabId, surfaceId)
    }
}
