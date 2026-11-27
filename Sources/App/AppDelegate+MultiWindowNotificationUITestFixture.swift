import Foundation

#if DEBUG
struct MultiWindowNotificationUITestFixture {
    let notification1: TerminalNotification?
    let notification2: TerminalNotification?
    let workspaceTitle1: String
    let workspaceTitle2: String
}

extension AppDelegate {
    func makeMultiWindowNotificationUITestFixture(
        first: (tabManager: TabManager, tabId: UUID),
        second: (tabManager: TabManager, tabId: UUID),
        store: TerminalNotificationStore
    ) -> MultiWindowNotificationUITestFixture {
        let workspaceTitle1 = "Notification Workspace One"
        let workspaceTitle2 = "Notification Workspace Two"
        first.tabManager.setCustomTitle(
            tabId: first.tabId,
            title: workspaceTitle1,
            propagateToRemoteTmux: false
        )
        second.tabManager.setCustomTitle(
            tabId: second.tabId,
            title: workspaceTitle2,
            propagateToRemoteTmux: false
        )

        // Ensure the second notification isn't suppressed just because its window is focused.
        let previousFocusOverride = AppFocusState.overrideIsFocused
        AppFocusState.overrideIsFocused = false
        store.addNotification(
            tabId: second.tabId,
            surfaceId: nil,
            title: "W2",
            subtitle: "multiwindow",
            body: ""
        )
        AppFocusState.overrideIsFocused = previousFocusOverride

        // Insert after W2 so it becomes the latest unread notification (first in the list).
        store.addNotification(
            tabId: first.tabId,
            surfaceId: nil,
            title: "W1",
            subtitle: "multiwindow",
            body: ""
        )

        return MultiWindowNotificationUITestFixture(
            notification1: store.notifications.first {
                $0.tabId == first.tabId && $0.title == "W1"
            },
            notification2: store.notifications.first {
                $0.tabId == second.tabId && $0.title == "W2"
            },
            workspaceTitle1: workspaceTitle1,
            workspaceTitle2: workspaceTitle2
        )
    }
}
#endif
