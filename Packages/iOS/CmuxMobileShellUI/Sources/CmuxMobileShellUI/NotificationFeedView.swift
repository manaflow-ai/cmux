#if os(iOS)
import CmuxMobileShellModel
import SwiftUI
import UIKit

/// Temporary bridge for SwiftUI-owned navigation while the mobile root moves to UIKit.
struct NotificationFeedView: UIViewControllerRepresentable {
    let status: MobileNotificationFeedStatus
    let projection: NotificationFeedProjection
    let refreshesOnAppear: Bool
    let actions: NotificationFeedActions

    func makeUIViewController(context: Context) -> NotificationFeedViewController {
        NotificationFeedViewController(
            status: status,
            projection: projection,
            refreshesOnAppear: refreshesOnAppear,
            actions: actions
        )
    }

    func updateUIViewController(
        _ controller: NotificationFeedViewController,
        context: Context
    ) {
        controller.update(status: status)
        controller.updateSearchText(projection.searchText)
    }
}
#endif
