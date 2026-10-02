#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Adapts the observable shell store to the store-free feed presentation.
/// This is the only notification-feed view that retains a store reference.
struct NotificationFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.mobilePrimarySearchDestination) private var isSearchDestination
    let items: [MobileNotificationFeedItem]
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let selectedMacDeviceIDs: Set<String>?

    var body: some View {
        NotificationFeedView(
            status: status,
            projection: projection,
            refreshesOnAppear: !isSearchDestination,
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
                Task { await store.markNotificationFeedItemsRead(scopedTo: selectedMacDeviceIDs) }
            },
            refresh: {
                await store.refreshNotificationFeed()
            }
        )
    }
}
#endif
