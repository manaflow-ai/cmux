import SwiftUI

/// An optional leading pin and an unread badge over the icon, with no empty
/// leading column. Read/unread changes never move the row's icon or title.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool

    func body(content: Content) -> some View {
        // Keep the pin in the same compact leading cluster as the row icon.
        // Four points made the unread badge spill past the narrow sidebar's
        // identity column; two points matches the tree's shared gaps.
        HStack(spacing: 2) {
            if isPinned {
                CmuxSystemSymbolImage(
                    magnified: "pin.fill",
                    pointSize: 9,
                    weight: .semibold,
                    tint: .secondary
                )
                    .fixedSize()
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
                .overlay(alignment: .topLeading) {
                    if showsAttentionSlot {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .opacity(hasUnreadNotification ? 1 : 0)
                            .accessibilityHidden(!hasUnreadNotification)
                            .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                            .help(hasUnreadNotification
                                ? String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification") : "")
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
