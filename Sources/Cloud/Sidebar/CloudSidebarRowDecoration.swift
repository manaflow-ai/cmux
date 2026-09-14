import SwiftUI

/// Fixed attention slot before the row icon; pins sit with trailing accessories.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool

    func body(content: Content) -> some View {
        HStack(spacing: 4) {
            if showsAttentionSlot {
                // Always mounted: in-place outline reloads must repaint both the
                // unread and read states without inserting a new SwiftUI subtree.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(hasUnreadNotification ? 1 : 0)
                    .accessibilityHidden(!hasUnreadNotification)
                    .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                    .help(hasUnreadNotification
                        ? String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification") : "")
            }
            content
            if isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
        }
    }
}
