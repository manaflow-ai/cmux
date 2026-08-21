#if os(iOS)
import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Adapts the observable shell store to the store-free feed presentation.
/// This is the only notification-feed view that retains a store reference.
struct NotificationFeedStoreView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.mobilePrimarySearchDestination) private var isSearchDestination
    /// Optional so previews and package hosts without the app root still render.
    @Environment(MobilePushCoordinator.self) private var pushCoordinator:
        MobilePushCoordinator?
    @Environment(MobileGuidanceStore.self) private var guidanceStore:
        MobileGuidanceStore?
    let items: [MobileNotificationFeedItem]
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let selectedMacDeviceIDs: Set<String>?

    var body: some View {
        VStack(spacing: 0) {
            if showsPushGuidance {
                MobileGuidanceCallout(
                    icon: "bell.badge",
                    title: L10n.string(
                        "mobile.guidance.push.title",
                        defaultValue: "Get these as push notifications"
                    ),
                    message: L10n.string(
                        "mobile.guidance.push.message",
                        defaultValue: "This feed works without alerts, but push pings you the moment an agent needs you, and you can reply from the notification."
                    ),
                    actionTitle: L10n.string(
                        "mobile.guidance.push.action",
                        defaultValue: "Enable Push"
                    ),
                    action: enablePushFromGuidance,
                    dismiss: { guidanceStore?.dismiss(.enablePushAlerts) }
                )
            }
            NotificationFeedView(
                status: status,
                projection: projection,
                refreshesOnAppear: !isSearchDestination,
                actions: actions
            )
        }
        .onAppear {
            store.recordAppEvent(.notificationFeedOpened, count: items.count)
        }
        .onDisappear {
            store.cancelPendingNotificationFeedOpen()
            store.recordAppEvent(.notificationFeedClosed)
        }
    }

    /// The push offer continues here for anyone who skipped or declined it in
    /// onboarding; it disappears for good on enable or dismissal.
    private var showsPushGuidance: Bool {
        guard !isSearchDestination,
              let pushCoordinator,
              let guidanceStore else { return false }
        return !pushCoordinator.isEnabled
            && !guidanceStore.isDismissed(.enablePushAlerts)
    }

    /// Enabling from the callout dismisses it either way: on a grant push is
    /// on, and after a denial the Settings push section owns recovery (its
    /// repair row deep-links to iOS Settings), so re-showing the same card
    /// would mislead.
    private func enablePushFromGuidance() {
        guard let pushCoordinator, let guidanceStore else { return }
        Task { @MainActor in
            _ = await pushCoordinator.enable(
                trigger: "guidance_notification_feed"
            )
            guidanceStore.dismiss(.enablePushAlerts)
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
}
#endif
