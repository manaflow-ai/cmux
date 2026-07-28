import CmuxSettings
import SwiftUI

/// Compact-on-idle notification tray that expands into a scrollable list on hover.
struct DynamicNotchNotificationTrayView: View {
    let model: DynamicNotchNotificationTrayModel
    let performAction: (String, [String: String], TerminalNotification) -> Void

    @State private var listContentHeight: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notifications = model.notifications
        let appearance = model.trayAppearance
        let animationDuration = Double(appearance.dimension(.animationDuration))
        let expandedHeight = min(
            max(listContentHeight, 1),
            appearance.dimension(.maximumExpandedHeight)
        )

        DynamicNotchNotificationListView(
            notifications: notifications,
            isExpanded: model.phase == .expanded,
            viewportHeight: expandedHeight,
            globalAppearance: model.globalAppearance,
            trayAppearance: appearance,
            contentHeightChanged: { height in
                if reduceMotion {
                    listContentHeight = height
                } else {
                    withAnimation(.snappy(duration: animationDuration)) {
                        listContentHeight = height
                    }
                }
            },
            performAction: performAction
        )
        .frame(
            width: appearance.dimension(.expandedWidth),
            height: expandedHeight,
            alignment: .top
        )
        .contentShape(Rectangle())
        .clipped()
        .animation(
            reduceMotion ? nil : .snappy(duration: animationDuration),
            value: notifications.map(\.id)
        )
        .tint(appearance.color(.accentColor, system: .accentColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DynamicNotchNotificationTray")
    }
}
