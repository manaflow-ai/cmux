import SwiftUI

/// An unread badge in the leading identity column, followed by an optional pin.
/// Read/unread changes never move the row's icon or title.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool
    var attentionSlot: CGFloat = CloudTreeStyle.compact.rowGrid.attentionSlot

    func body(content: Content) -> some View {
        // Reserve the attention column even when the row is read. This keeps
        // the icon and title stable across unread transitions while limiting
        // the gutter to rows that can actually carry notifications.
        HStack(spacing: 2) {
            if showsAttentionSlot {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(hasUnreadNotification ? 1 : 0)
                    .accessibilityHidden(!hasUnreadNotification)
                    .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                    .help(hasUnreadNotification
                        ? String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification") : "")
                    .frame(width: attentionSlot)
                    .allowsHitTesting(false)
            }
            if isPinned {
                Image(systemName: "pin.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
        }
    }
}
