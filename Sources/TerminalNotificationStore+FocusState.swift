import Foundation

extension TerminalNotificationStore {
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
