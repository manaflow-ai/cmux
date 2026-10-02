#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// Adapts the observable shell store to the store-free feed presentation.
/// This is the only notification-feed view that retains a store reference.
struct NotificationFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    @Binding var isConfirmingMarkAllRead: Bool
    @Environment(\.mobilePrimarySearchDestination) private var isSearchDestination
    let items: [MobileNotificationFeedItem]
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let selectedMacDeviceIDs: Set<String>?
    var isActive = true
    var showsNavigationToolbar = true
    @State private var isFeedVisible = false

    var body: some View {
        NotificationFeedView(
            status: status,
            projection: projection,
            // The mounted tab and the active search destination both use the
            // active gate below, so only the visible owner refreshes.
            refreshesOnAppear: true,
            actions: actions,
            isActive: isActive,
            isConfirmingMarkAllRead: $isConfirmingMarkAllRead,
            showsNavigationToolbar: showsNavigationToolbar
        )
        .onAppear {
            updateFeedVisibility(isActive)
        }
        .onChange(of: isActive) { _, active in
            if !active {
                store.cancelPendingNotificationFeedOpen()
            }
            updateFeedVisibility(active)
        }
        .onDisappear {
            store.cancelPendingNotificationFeedOpen()
            updateFeedVisibility(false)
        }
    }

    private var actions: NotificationFeedActions {
        let store = store
        return NotificationFeedActions(
            open: { item in
                if isSearchDestination {
                    store.recordAppEvent(
                        .searchResultSelected,
                        correlationID: item.notificationID,
                        detail: .searchScope(.notifications)
                    )
                }
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
            },
            loadMore: {
                store.recordAppEvent(.notificationFeedLoadMoreStarted)
                store.recordAppEvent(.notificationFeedLoadMoreSucceeded)
            },
            filterChanged: { filter in
                store.recordAppEvent(
                    .notificationFeedFilterChanged,
                    count: filter == .unread ? 1 : 0
                )
            }
        )
    }

    private func updateFeedVisibility(_ active: Bool) {
        if active {
            guard !isFeedVisible else { return }
            isFeedVisible = true
            store.recordAppEvent(.notificationFeedOpened, count: items.count)
        } else {
            guard isFeedVisible else { return }
            isFeedVisible = false
            store.cancelPendingNotificationFeedOpen()
            store.recordAppEvent(.notificationFeedClosed)
        }
    }
}
#endif
