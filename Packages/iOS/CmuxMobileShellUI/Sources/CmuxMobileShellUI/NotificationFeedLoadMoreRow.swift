#if os(iOS)
import CmuxMobileSupport
import SwiftUI

/// The sentinel row after the last mounted section. Its appearance means the
/// user reached the mounted span's end, so the projection mounts the next
/// window of rows; appending below the viewport never shifts scroll position.
struct NotificationFeedLoadMoreRow: View {
    let loadMore: @MainActor () -> Void

    var body: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 10)
        .listRowSeparator(.hidden)
        .accessibilityLabel(L10n.string(
            "mobile.notificationFeed.loadingMore",
            defaultValue: "Loading more notifications"
        ))
        .accessibilityIdentifier("MobileNotificationFeedLoadMore")
        .onAppear(perform: loadMore)
    }
}
#endif
