import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Thin live wrapper that projects shell state into the value-driven feed.
struct NotificationFeedScreen: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(MobilePushCoordinator.self) private var pushCoordinator
    @Environment(\.dismiss) private var dismiss
    private let introStore: MobileNotificationFeedIntroStore
    @State private var showsIntro: Bool
    @State private var pushEnabled = false

    init(store: CMUXMobileShellStore, introStore: MobileNotificationFeedIntroStore) {
        self.store = store
        self.introStore = introStore
        _showsIntro = State(initialValue: !introStore.hasDismissedIntro)
    }

    var body: some View {
        let sections = NotificationFeedDayGrouping(now: .now, calendar: .current)
            .sections(for: store.notificationFeed.items, createdAt: \.createdAt)
            .map { NotificationFeedSection(day: $0.day, items: $0.items) }
        NavigationStack {
            NotificationFeedView(
                sections: sections,
                isRefreshing: store.notificationFeed.isRefreshing,
                hasLoaded: store.notificationFeed.hasLoaded,
                showsIntro: showsIntro,
                pushEnabled: pushEnabled,
                actions: actions
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(L10n.string("mobile.notifications.close", defaultValue: "Close"))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: markAllRead) {
                        Image(systemName: "checkmark.circle")
                    }
                    .disabled(store.notificationFeed.unreadCount == 0)
                    .accessibilityLabel(L10n.string(
                        "mobile.notifications.markAllRead",
                        defaultValue: "Mark All Read"
                    ))
                    .accessibilityIdentifier("MobileNotificationMarkAllRead")
                }
            }
        }
        .task {
            pushEnabled = pushCoordinator.isEnabled
            await store.refreshNotificationFeed()
        }
    }

    private var actions: NotificationFeedActions {
        NotificationFeedActions(
            refresh: { await store.refreshNotificationFeed() },
            open: { item in
                dismiss()
                Task { await store.openNotificationFeedItem(item) }
            },
            toggleRead: { item in
                Task {
                    if item.isRead {
                        await store.markNotificationUnread(id: item.id)
                    } else {
                        await store.markNotificationsRead(ids: [item.id])
                    }
                }
            },
            remove: { item in
                Task { await store.removeNotifications(ids: [item.id]) }
            },
            dismissIntro: {
                introStore.markDismissed()
                showsIntro = false
            },
            enablePush: {
                Task { pushEnabled = await pushCoordinator.enable() }
            }
        )
    }

    private func markAllRead() {
        Task {
            await store.markAllNotificationsRead()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}
