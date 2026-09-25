import CmuxSettings
import Foundation

extension TerminalNotificationStore.NotificationFocusState {
    /// The notification targets the exact surface the user is looking at.
    var isFocusedSurfaceArrival: Bool {
        isAppFocused && isActiveTab && isFocusedSurface
    }
}

extension TerminalNotificationStore {
    private static let notificationsSettings = NotificationsCatalogSection()

    /// Opt-in `notifications.suppressWhenAppFocused` (issue #3126): when on,
    /// any notification that arrives while cmux is the active app skips the
    /// desktop banner and phone forward, not only one for the focused surface.
    static func isSuppressWhenAppFocusedEnabled(defaults: UserDefaults = .standard) -> Bool {
        notificationsSettings.suppressWhenAppFocused.value(in: defaults)
    }

    static func shouldSuppressExternalDelivery(
        _ focusState: NotificationFocusState,
        suppressWhenAppFocused: Bool = isSuppressWhenAppFocusedEnabled()
    ) -> Bool {
        if suppressWhenAppFocused {
            return focusState.isAppFocused
        }
        return focusState.isFocusedSurfaceArrival
    }

    func notificationFocusState(
        tabId: UUID,
        surfaceId: UUID?
    ) -> NotificationFocusState {
        let appDelegate = AppDelegate.shared
        let context = appDelegate?.contextContainingTabId(tabId)
        let tabManager = context?.tabManager
            ?? appDelegate?.tabManagerFor(tabId: tabId)
            ?? appDelegate?.tabManager
        let focusedSurfaceId = tabManager?.focusedSurfaceId(for: tabId)
        return NotificationFocusState(
            isAppFocused: AppFocusState.isAppFocused(),
            isActiveTab: tabManager?.selectedTabId == tabId,
            isFocusedSurface: surfaceId == nil || focusedSurfaceId == surfaceId,
            workspace: tabManager?.workspacesById[tabId],
            cmuxConfigStore: context?.cmuxConfigStore
        )
    }

}
