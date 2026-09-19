import SwiftUI

/// An optional leading pin and an unread badge over the icon, with no empty
/// leading column. Read/unread changes never move the row's icon or title.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 4) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
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
