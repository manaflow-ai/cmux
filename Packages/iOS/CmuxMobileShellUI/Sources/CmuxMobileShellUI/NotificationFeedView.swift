#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Store-free actions passed through the feed's lazy-list boundary.
struct NotificationFeedActions {
    let open: @MainActor (MobileNotificationFeedItem) -> Void
    let markRead: @MainActor (MobileNotificationFeedItem) -> Void
    let markUnread: @MainActor (MobileNotificationFeedItem) -> Void
    let markAllRead: @MainActor () -> Void
    let refresh: @MainActor @Sendable () async -> Void
    let loadMore: @MainActor () -> Void
    let filterChanged: @MainActor (MobileNotificationFeedFilter) -> Void
}

/// Production notification-feed presentation. This view owns only UI projection
/// state; rows receive immutable item snapshots plus ``NotificationFeedActions``.
struct NotificationFeedView: View {
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let refreshesOnAppear: Bool
    let actions: NotificationFeedActions
    /// Mark-all-read cannot be undone in one gesture, so the toolbar button
    /// only arms this confirmation instead of mutating directly.
    @State private var isConfirmingMarkAllRead = false

    var body: some View {
        @Bindable var projection = projection

        VStack(spacing: 0) {
            NotificationFeedList(
                sections: projection.sections,
                sourceItemCount: projection.sourceItemCount,
                isSourceRebuilding: projection.isSourceRebuilding,
                hasStaleSourceSections: projection.hasStaleSourceSections,
                hasMoreRows: projection.hasMoreRows,
                filter: projection.filter,
                hasSearchQuery: !projection.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                status: status,
                actions: actions,
                loadMoreRows: {
                    actions.loadMore()
                    projection.extendRowWindow()
                }
            )
        }
        // No title of its own (the tab names the screen), so collapse the
        // large-title zone or the list opens with a bar-height blank strip.
        .mobileInlineNavigationTitle()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if projection.sourceUnreadCount > 0 {
                    Button {
                        isConfirmingMarkAllRead = true
                    } label: {
                        Label(
                            L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read"),
                            systemImage: "envelope.open"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(
                        L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read")
                    )
                    .accessibilityIdentifier("MobileNotificationFeedMarkAllRead")
                }

                NotificationFeedFilterMenu(selection: $projection.filter)
            }
        }
        .alert(
            L10n.string(
                "mobile.notificationFeed.markAllRead.confirmTitle",
                defaultValue: "Mark all notifications as read?"
            ),
            isPresented: $isConfirmingMarkAllRead
        ) {
            Button(
                L10n.string("mobile.notificationFeed.markAllRead", defaultValue: "Mark All Read"),
                role: .destructive
            ) {
                actions.markAllRead()
            }
            .accessibilityIdentifier("MobileNotificationFeedMarkAllReadConfirm")
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), role: .cancel) {}
                .accessibilityIdentifier("MobileNotificationFeedMarkAllReadCancel")
        }
        .task {
            guard refreshesOnAppear else { return }
            await actions.refresh()
        }
        .onChange(of: projection.filter) { _, filter in
            actions.filterChanged(filter)
        }
        .accessibilityIdentifier("MobileNotificationFeed")
    }
}

/// The feed twin of `WorkspaceListFilterMenu`: read state lives in a toolbar
/// menu instead of a segmented bar above the list, and the icon fills while a
/// narrowing filter is active, mirroring Mail.
private struct NotificationFeedFilterMenu: View {
    @Binding var selection: MobileNotificationFeedFilter

    var body: some View {
        Menu {
            Picker(
                L10n.string("mobile.notificationFeed.filter.label", defaultValue: "Notification filter"),
                selection: $selection
            ) {
                Text(L10n.string(
                    "mobile.notificationFeed.filter.allNotifications",
                    defaultValue: "All Notifications"
                ))
                .tag(MobileNotificationFeedFilter.all)
                Text(L10n.string("mobile.notificationFeed.filter.unread", defaultValue: "Unread"))
                    .tag(MobileNotificationFeedFilter.unread)
            }
        } label: {
            Image(systemName: selection == .unread
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel(L10n.string("mobile.notificationFeed.filter", defaultValue: "Filter"))
        .accessibilityIdentifier("MobileNotificationFeedFilterMenu")
    }
}

private struct NotificationFeedList: View {
    let sections: [NotificationFeedDaySection]
    let sourceItemCount: Int
    let isSourceRebuilding: Bool
    let hasStaleSourceSections: Bool
    let hasMoreRows: Bool
    let filter: MobileNotificationFeedFilter
    let hasSearchQuery: Bool
    let status: MobileNotificationFeedStatus
    let actions: NotificationFeedActions
    let loadMoreRows: @MainActor () -> Void

    var body: some View {
        List {
            if sourceItemCount > 0 {
                NotificationFeedAvailabilityBanner(status: status)
            }

            if sections.isEmpty {
                NotificationFeedEmptyRow(
                    state: emptyState,
                    retry: { Task { await actions.refresh() } }
                )
            } else {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.items) { model in
                            NotificationFeedRow(model: model, actions: actions)
                                .equatable()
                                .disabled(hasStaleSourceSections)
                                .allowsHitTesting(!hasStaleSourceSections)
                        }
                    } header: {
                        NotificationFeedDayHeader(section: section)
                    }
                }
                if hasMoreRows {
                    NotificationFeedLoadMoreRow(loadMore: loadMoreRows)
                }
            }
        }
        .listStyle(.plain)
        .refreshable {
            await actions.refresh()
        }
        .accessibilityIdentifier("MobileNotificationFeedList")
    }

    private var emptyState: NotificationFeedEmptyState {
        NotificationFeedEmptyState.resolve(
            sourceItemCount: sourceItemCount,
            filter: filter,
            hasSearchQuery: hasSearchQuery,
            isSourceRebuilding: isSourceRebuilding,
            status: status
        )
    }
}

private struct NotificationFeedDayHeader: View {
    let section: NotificationFeedDaySection

    var body: some View {
        Group {
            switch section.kind {
            case .today:
                Text(L10n.string("mobile.notificationFeed.day.today", defaultValue: "Today"))
            case .yesterday:
                Text(L10n.string("mobile.notificationFeed.day.yesterday", defaultValue: "Yesterday"))
            case .dated:
                Text(section.id, format: .dateTime.weekday(.wide).month(.abbreviated).day())
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(dayAccessibilityIdentifier)
    }

    private var dayAccessibilityIdentifier: String {
        switch section.kind {
        case .today: "MobileNotificationFeedDayToday"
        case .yesterday: "MobileNotificationFeedDayYesterday"
        case .dated: "MobileNotificationFeedDayDated"
        }
    }
}
#endif
