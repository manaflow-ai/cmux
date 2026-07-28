import AppKit
import CmuxAppKitSupportUI
import CmuxSettings
import SwiftUI

/// Scrollable, snapshot-driven rows for the expanded Dynamic Notch tray.
struct DynamicNotchNotificationListView: View {
    let notifications: [TerminalNotification]
    let isExpanded: Bool
    let viewportHeight: CGFloat
    let globalAppearance: DynamicNotchAppearance
    let trayAppearance: DynamicNotchAppearance
    let contentHeightChanged: (CGFloat) -> Void
    let performAction: (String, [String: String], TerminalNotification) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollTargetID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(
                    Array(notifications.enumerated()),
                    id: \.element.id
                ) { index, notification in
                    let appearance = globalAppearance.applying(
                        notification.presentation.appearance
                    )
                    VStack(spacing: 0) {
                        DynamicNotchNotificationView(
                            notification: notification,
                            isTrayExpanded: isExpanded,
                            shouldAutofocus: index == 0,
                            appearance: appearance
                        ) { action, values in
                            performAction(action, values, notification)
                        }

                        if index < notifications.count - 1 {
                            Divider()
                                .overlay(
                                    trayAppearance.color(
                                        .dividerColor,
                                        system: Color(nsColor: .separatorColor)
                                    )
                                )
                                .padding(
                                    .horizontal,
                                    trayAppearance.dimension(.dividerHorizontalPadding)
                                )
                        }
                    }
                    .id(notification.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                }
            }
            .scrollTargetLayout()
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(duration: animationDuration),
                value: notifications.map(\.id)
            )
            .onGeometryChange(for: CGFloat.self, of: \.size.height) {
                contentHeightChanged($0)
            }
            .background {
                SidebarScrollViewResolver { scrollView in
                    scrollView?.applyDynamicNotchScrollerConfiguration(
                        showsIndicators: trayAppearance.boolean(
                            .showScrollIndicators
                        )
                    )
                }
                .frame(width: 0, height: 0)
            }
        }
        .scrollPosition(id: $scrollTargetID, anchor: .top)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.horizontal, 0, for: .scrollIndicators)
        .frame(
            width: trayAppearance.dimension(.expandedWidth),
            height: viewportHeight
        )
        .onChange(of: notifications.first?.id) { _, newestID in
            scrollToNewest(newestID, animated: true)
        }
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            scrollToNewest(notifications.first?.id, animated: false)
        }
        .accessibilityIdentifier("DynamicNotchNotificationList")
    }

    private func scrollToNewest(
        _ newestID: UUID?,
        animated: Bool
    ) {
        guard isExpanded, let newestID else { return }
        if reduceMotion || !animated {
            scrollTargetID = newestID
        } else {
            withAnimation(.snappy(duration: animationDuration)) {
                scrollTargetID = newestID
            }
        }
    }

    private var animationDuration: Double {
        Double(trayAppearance.dimension(.animationDuration))
    }
}

private extension NSScrollView {
    @MainActor
    func applyDynamicNotchScrollerConfiguration(
        showsIndicators: Bool
    ) {
        applyOverlayScrollerConfiguration(
            showsVerticalScroller: showsIndicators
        )
        if automaticallyAdjustsContentInsets {
            automaticallyAdjustsContentInsets = false
        }

        let currentContentInsets = contentInsets
        if currentContentInsets.left != 0 || currentContentInsets.right != 0 {
            contentInsets = NSEdgeInsets(
                top: currentContentInsets.top,
                left: 0,
                bottom: currentContentInsets.bottom,
                right: 0
            )
        }

        let currentScrollerInsets = scrollerInsets
        if currentScrollerInsets.left != 0
            || currentScrollerInsets.right != 0 {
            scrollerInsets = NSEdgeInsets(
                top: currentScrollerInsets.top,
                left: 0,
                bottom: currentScrollerInsets.bottom,
                right: 0
            )
        }
    }
}
