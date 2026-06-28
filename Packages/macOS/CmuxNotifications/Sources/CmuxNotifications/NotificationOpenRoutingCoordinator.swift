public import Foundation

/// Owns the notification-open *decision skeleton* lifted verbatim from
/// `AppDelegate`'s `openNotification(tabId:surfaceId:notificationId:)`,
/// `openNotificationInContext(_:tabId:surfaceId:notificationId:)`, and
/// `openNotificationFallback(tabId:surfaceId:notificationId:)`.
///
/// The routing decision is: resolve the registered window context that owns the
/// tab; if found, open in that context (select sidebar tabs, bring its window to
/// front, focus the tab, mark read); if not, fall back to the active window
/// (guard the active tab manager owns the tab and a key/main terminal window
/// exists, then the same select/front/focus/mark sequence). The window
/// mechanics and the `#if DEBUG` UI-test recorders stay app-side behind
/// ``NotificationOpenRoutingHosting`` and ``NotificationOpenRoutingTracing``;
/// this coordinator only decides *which* route to take and *in what order* to
/// drive the seam.
///
/// A Coordinator (CONVENTIONS §2): it sequences a flow and owns no I/O.
/// `@MainActor` because every open-routing entry point is a MainActor UI path
/// and both seams it drives are `@MainActor`.
@MainActor
public final class NotificationOpenRoutingCoordinator {
    private let host: any NotificationOpenRoutingHosting
    private let tracing: any NotificationOpenRoutingTracing

    public init(
        host: any NotificationOpenRoutingHosting,
        tracing: any NotificationOpenRoutingTracing
    ) {
        self.host = host
        self.tracing = tracing
    }

    /// Focuses `tabId`/`surfaceId`, marking `notificationId` read on success.
    /// Routes to the owning registered window, falling back to the active window
    /// when no context owns the tab. Mirrors `AppDelegate.openNotification`.
    @discardableResult
    public func openRouted(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        tracing.traceOpenCalled(tabId: tabId, surfaceId: surfaceId)
        guard let contextToken = host.contextToken(forTabId: tabId) else {
            tracing.recordOpenFailureMissingContext(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId
            )
            tracing.traceContextMissingUsedFallback()
            let ok = openFallback(tabId: tabId, surfaceId: surfaceId, notificationId: notificationId)
            tracing.traceOpenResult(ok)
            return ok
        }
        tracing.traceContextFoundNoFallback()
        return openInContext(
            contextToken,
            tabId: tabId,
            surfaceId: surfaceId,
            notificationId: notificationId
        )
    }

    /// Opens in the specific registered window context `contextToken`. Mirrors
    /// `AppDelegate.openNotificationInContext`.
    @discardableResult
    public func openInContext(
        _ contextToken: AnyObject,
        tabId: UUID,
        surfaceId: UUID?,
        notificationId: UUID?
    ) -> Bool {
        guard let windowToken = host.contextWindowToken(forContextToken: contextToken) else {
            tracing.recordOpenFailureMissingWindow(
                forContextToken: contextToken,
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId
            )
            return false
        }

        host.selectSidebarTabs(forContextToken: contextToken)
        host.bringWindowToFront(windowToken)
        guard host.focusTabFromNotification(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        ) else {
            tracing.traceInContextFocusFailed(
                forContextToken: contextToken,
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId
            )
            return false
        }

        tracing.recordJumpUnreadFocusFromModelInContext(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        )

        host.markNotificationRead(notificationId: notificationId)

        tracing.traceInContextOpened(
            forContextToken: contextToken,
            tabId: tabId,
            surfaceId: surfaceId
        )
        return true
    }

    /// Opens in the active window when no registered context owns the tab.
    /// Mirrors `AppDelegate.openNotificationFallback`.
    @discardableResult
    public func openFallback(tabId: UUID, surfaceId: UUID?, notificationId: UUID?) -> Bool {
        guard host.hasActiveTabManager else {
            tracing.traceFallbackFailed(stage: "missing_tabManager")
            return false
        }
        guard host.activeTabManagerContains(tabId: tabId) else {
            tracing.traceFallbackFailed(stage: "tab_not_in_active_manager")
            return false
        }
        guard let windowToken = host.keyOrMainTerminalWindowToken() else {
            tracing.traceFallbackFailed(stage: "missing_window")
            return false
        }

        host.selectActiveSidebarTabs()
        host.bringWindowToFront(windowToken)
        guard host.focusTabInActiveTabManager(tabId: tabId, surfaceId: surfaceId) else {
            tracing.traceFallbackFocusFailed()
            return false
        }

        tracing.recordJumpUnreadFocusFromModelActive(tabId: tabId, surfaceId: surfaceId)

        host.markNotificationRead(notificationId: notificationId)

        tracing.traceOpenedInFallback()
        return true
    }
}
