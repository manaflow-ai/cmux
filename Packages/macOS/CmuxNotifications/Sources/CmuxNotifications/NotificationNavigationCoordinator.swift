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
/// `markFocusedNotificationAsOldestUnread*`) now lives in
/// ``FocusedNotificationMarker``, owned by this coordinator and driven through
/// the ``FocusedNotificationResolving`` seam; the coordinator exposes the two
/// public focused-mark entry points and forwards to the marker, which delegates
/// its jump step back to ``jumpToLatestUnread(excludingNotificationId:excludingWorkspaceId:)``.
@MainActor
@Observable
public final class NotificationNavigationCoordinator: NotificationDeliveryTerminalNavigating {
    private let store: any NotificationNavigationStoreReading
    private let windows: any MainWindowContextResolving
    private let unreadTargeting: any UnreadWorkspaceTargeting
    private let openRouting: any NotificationOpenRouting
    private let clickRouting: any NotificationClickRouting
    private let focusedResolving: any FocusedNotificationResolving
    private let explicitFocusedJump: ((UUID?, UUID?) -> UUID?)?
    /// The focused-mark state machine. Lazy so its default jump closure can
    /// capture `self` (allowed only after all stored properties are initialized);
    /// the closure is invoked later, on the main actor. `@ObservationIgnored`
    /// because this is a private internal collaborator that must not participate
    /// in `@Observable` observation; the enclosing type is `@MainActor`, so the
    /// lazy initialization is concurrency-safe.
    @ObservationIgnored
    private lazy var focusedMarker: FocusedNotificationMarker = FocusedNotificationMarker(
        resolver: focusedResolving,
        jumpToLatestUnread: explicitFocusedJump ?? { [unowned self] excludedNotificationId, excludedWorkspaceId in
            self.jumpToLatestUnread(
                excludingNotificationId: excludedNotificationId,
                excludingWorkspaceId: excludedWorkspaceId
            )
        }
    )

    /// Signalled after a jump/open focuses a workspace/surface, so the app-target
    /// `#if DEBUG` jump-unread UI-test recorders (which observe Combine and
    /// first-responder events the package must not import) can arm/record. Carries
    /// the focused `(tabId, surfaceId?)`. No-op in production builds.
    public var onDidFocusForJumpUnread: ((UUID, UUID?) -> Void)?

    /// - Parameter focusedJump: the jump the focused-mark flow performs after
    ///   marking oldest-unread, returning the opened notification id. Injected so
    ///   the app target can route it through its own recorder-wrapped
    ///   `jumpToLatestUnread` (which fires the `#if DEBUG` `jumpUnreadInvoked`
    ///   UI-test recorder and applies the nil-store guard), preserving byte-identical
    ///   recorder behavior. Defaults to this coordinator's plain
    ///   ``jumpToLatestUnread(excludingNotificationId:excludingWorkspaceId:)``.
    public init(
        store: any NotificationNavigationStoreReading,
        windows: any MainWindowContextResolving,
        unreadTargeting: any UnreadWorkspaceTargeting,
        openRouting: any NotificationOpenRouting,
        clickRouting: any NotificationClickRouting,
        focusedResolving: any FocusedNotificationResolving,
        focusedJump: ((_ excludingNotificationId: UUID?, _ excludingWorkspaceId: UUID?) -> UUID?)? = nil
    ) {
        self.store = store
        self.windows = windows
        self.unreadTargeting = unreadTargeting
        self.openRouting = openRouting
        self.clickRouting = clickRouting
        self.focusedResolving = focusedResolving
        self.explicitFocusedJump = focusedJump
    }

    // MARK: Focused-mark

    /// Toggles the focused notification's unread state, returning whether
    /// anything was toggled. Forwards to ``FocusedNotificationMarker``. Mirrors
    /// `AppDelegate.toggleFocusedNotificationUnread`.
    @discardableResult
    public func toggleFocusedNotificationUnread(preferredWindowToken: AnyObject? = nil) -> Bool {
        focusedMarker.toggleFocusedNotificationUnread(preferredWindowToken: preferredWindowToken)
    }

    /// Marks the focused notification oldest-unread, then jumps to the next
    /// latest unread, returning the opened notification id. Forwards to
    /// ``FocusedNotificationMarker``. Mirrors
    /// `AppDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread`.
    @discardableResult
    public func markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
        preferredWindowToken: AnyObject? = nil
    ) -> UUID? {
        focusedMarker.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(
            preferredWindowToken: preferredWindowToken
        )
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
        // workspace, which is NOT necessarily in the window-context registry:
        // during early startup / VM timing the registry lags behind model init,
        // so `orderedTargetsForUnreadJump` can be empty while the active manager
        // already owns the unread workspace. Resolve it from the active manager
        // directly, mirroring the legacy `self.tabManager.tabs.first(where:)`.
        guard let workspaceId = windows.activeWorkspaceIdsForUnreadJump
            .first(where: { unreadWorkspaceIds.contains($0) }) else {
            return false
        }
        let panelId = unreadTargeting.preferredUnreadPanelIdForJump(workspaceId: workspaceId)
        let didOpen = openRouting.openInActiveWindowFallback(
            tabId: workspaceId,
            surfaceId: panelId,
            panelId: nil,
            notificationId: nil,
            scrollRow: nil
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
            panelId: nil,
            notificationId: nil,
            scrollRow: nil
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
            panelId: notification.panelId,
            notificationId: notification.id,
            scrollRow: notification.scrollRow
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
        open(tabId: tabId, surfaceId: surfaceId, panelId: nil, notificationId: notificationId, scrollRow: nil)
    }

    /// Focuses `tabId`/`surfaceId`, marks `notificationId` read on success, and
    /// optionally restores terminal scrollback context.
    ///
    /// - Parameters:
    ///   - tabId: Workspace id that owns the notification.
    ///   - surfaceId: Surface id to focus when the notification is surface-scoped.
    ///   - panelId: App-target terminal panel id used only to restore scroll
    ///     context when it differs from, or is more precise than, `surfaceId`.
    ///   - notificationId: Notification id to mark read after focus succeeds.
    ///   - scrollRow: Top-relative terminal scrollback row captured when the
    ///     notification was recorded. The app-side router converts it to the
    ///     live bottom-relative Ghostty scroll action after focus.
    @discardableResult
    public func open(tabId: UUID, surfaceId: UUID?, panelId: UUID?, notificationId: UUID?, scrollRow: Int?) -> Bool {
        openRouting.openRouted(
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            notificationId: notificationId,
            scrollRow: scrollRow
        )
    }

    /// Performs a terminal notification click action through the injected click
    /// routing seam. Used by ``NotificationDeliveryCoordinator`` for tapped OS
    /// notifications that carry click-action userInfo.
    @discardableResult
    public func performClickAction(_ action: NotificationNavClickAction) -> Bool {
        clickRouting.perform(action)
    }

    /// Marks a terminal notification read through the injected store seam. Used
    /// by ``NotificationDeliveryCoordinator`` for dismissed OS notifications and
    /// successfully performed click actions.
    public func markNotificationRead(id: UUID) {
        store.markRead(id: id)
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
