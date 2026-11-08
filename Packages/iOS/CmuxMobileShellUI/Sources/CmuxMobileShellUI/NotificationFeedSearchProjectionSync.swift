#if os(iOS)
import SwiftUI

struct NotificationFeedSearchProjectionSync: View {
    @Bindable var searchCoordinator: MobilePrimarySearchCoordinator
    let projection: NotificationFeedProjection

    var body: some View {
        let searchText = searchCoordinator.isPresented && searchCoordinator.scope == .notifications
            ? searchCoordinator.searchDestinationText(for: .notifications)
            : searchCoordinator.committedSearchText(for: .notifications)
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: searchText, initial: true) { _, searchText in
                projection.searchText = searchText
            }
    }
}
#endif
