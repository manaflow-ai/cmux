#if os(iOS)
import CmuxMobileShell
import SwiftUI

/// Adapts the observable shell store to the store-free feed presentation.
/// This is the only notification-feed view that retains a store reference.
struct NotificationFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore

    var body: some View {
        NavigationStack {
            NotificationFeedView(
                items: store.notificationFeedItems,
                status: store.notificationFeedStatus,
                actions: actions
            )
        }
    }

    private var actions: NotificationFeedActions {
        let store = store
        return NotificationFeedActions(
            open: { item in
                Task { await store.openNotificationFeedItem(item) }
            },
            markRead: { item in
                Task { await store.markNotificationFeedItemRead(item) }
            },
            markAllRead: {
                Task { await store.markAllNotificationFeedItemsRead() }
            },
            refresh: {
                await store.refreshNotificationFeed()
            }
        )
    }
}
#endif
