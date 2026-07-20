#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Adapts the observable shell store to the store-free feed presentation.
/// This is the only notification-feed view that retains a store reference.
struct NotificationFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    let items: [MobileNotificationFeedItem]
    let status: MobileNotificationFeedStatus

    var body: some View {
        NotificationFeedView(
            items: items,
            status: status,
            actions: actions
        )
        .onDisappear {
            store.cancelPendingNotificationFeedOpen()
        }
    }

    private var actions: NotificationFeedActions {
        let store = store
        return NotificationFeedActions(
            open: { item in
                store.requestOpenNotificationFeedItem(item)
            },
            markRead: { item in
                Task { await store.markNotificationFeedItemRead(item) }
            },
            markUnread: { item in
                Task { await store.markNotificationFeedItemUnread(item) }
            },
            markAllRead: {
                Task { await store.markNotificationFeedItemsRead(items) }
            },
            refresh: {
                await store.refreshNotificationFeed()
            }
        )
    }
}
#endif
