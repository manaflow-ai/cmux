import SwiftUI

/// Scrollable, snapshot-driven rows for the expanded Dynamic Notch tray.
struct DynamicNotchNotificationListView: View {
    let notifications: [TerminalNotification]
    let isExpanded: Bool
    let viewportHeight: CGFloat
    let contentHeightChanged: (CGFloat) -> Void
    let performAction: (String, [String: String], TerminalNotification) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(notifications.enumerated(), id: \.element.id) { index, notification in
                    VStack(spacing: 0) {
                        DynamicNotchNotificationView(
                            notification: notification,
                            isTrayExpanded: isExpanded,
                            shouldAutofocus: index == 0
                        ) { action, values in
                            performAction(action, values, notification)
                        }

                        if index < notifications.count - 1 {
                            Divider()
                                .padding(.horizontal, 18)
                        }
                    }
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                contentHeightChanged($0)
            }
        }
        .scrollIndicators(.automatic)
        .frame(width: 460, height: viewportHeight)
        .accessibilityIdentifier("DynamicNotchNotificationList")
    }
}
