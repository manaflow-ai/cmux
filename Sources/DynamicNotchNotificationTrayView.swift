import SwiftUI

/// Compact-on-idle notification tray that expands into a scrollable list on hover.
struct DynamicNotchNotificationTrayView: View {
    private static let compactWidth: CGFloat = 104
    private static let compactHeight: CGFloat = 32
    private static let expandedWidth: CGFloat = 460
    private static let maximumExpandedHeight: CGFloat = 520

    let model: DynamicNotchNotificationTrayModel
    let hoverChanged: (Bool) -> Void
    let performAction: (String, [String: String], TerminalNotification) -> Void

    @State private var listContentHeight = Self.compactHeight

    var body: some View {
        let notifications = model.notifications
        let isExpanded = model.isExpanded
        let expandedHeight = min(
            max(listContentHeight, Self.compactHeight),
            Self.maximumExpandedHeight
        )

        ZStack(alignment: .top) {
            DynamicNotchNotificationListView(
                notifications: notifications,
                isExpanded: isExpanded,
                viewportHeight: expandedHeight,
                contentHeightChanged: { listContentHeight = $0 },
                performAction: performAction
            )
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)

            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    model.setExpanded(true)
                }
                hoverChanged(true)
            } label: {
                DynamicNotchNotificationCompactView(count: notifications.count)
            }
            .buttonStyle(.plain)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(!isExpanded)
            .accessibilityHidden(isExpanded)
            .accessibilityIdentifier("DynamicNotchNotificationExpand")
        }
        .frame(
            width: isExpanded ? Self.expandedWidth : Self.compactWidth,
            height: isExpanded ? expandedHeight : Self.compactHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
        .clipped()
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.28)) {
                model.setExpanded(hovering)
            }
            hoverChanged(hovering)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DynamicNotchNotificationTray")
    }
}
