#if os(iOS)
import CMUXMobileCore
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
        .onAppear {
            store.recordAppEvent(.notificationFeedOpened, count: items.count)
        }
        .onDisappear {
            store.cancelPendingNotificationFeedOpen()
            store.recordAppEvent(.notificationFeedClosed)
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
            reply: { item, text in
                await store.replyToNotificationFeedItem(item, text: text)
            },
            decidePermission: { item, mode in
                await store.resolveNotificationFeedPermission(item, mode: mode)
            },
            decideExitPlan: { item, mode, feedback in
                await store.resolveNotificationFeedExitPlan(item, mode: mode, feedback: feedback)
            },
            answerQuestions: { item, answers in
                await store.resolveNotificationFeedQuestions(item, answers: answers)
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
}
#endif
