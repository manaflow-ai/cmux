import SwiftUI

/// Fixed attention slot and optional pin before the row's icon and title.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool
    let showsPinSlot: Bool

    init(
        isPinned: Bool,
        showsAttentionSlot: Bool,
        hasUnreadNotification: Bool,
        showsPinSlot: Bool
    ) {
        self.isPinned = isPinned
        self.showsAttentionSlot = showsAttentionSlot
        self.hasUnreadNotification = hasUnreadNotification
        self.showsPinSlot = showsPinSlot
    }

    func body(content: Content) -> some View {
        HStack(spacing: CloudTreeRowGrid.accessoryGap) {
            if showsAttentionSlot {
                // Always mounted: in-place outline reloads repaint read/unread without reflow.
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .opacity(hasUnreadNotification ? 1 : 0)
                    .accessibilityHidden(!hasUnreadNotification)
                    .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                    .help(hasUnreadNotification
                        ? String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification") : "")
                    .frame(width: CloudTreeRowGrid.attentionSlot)
            }
            if showsPinSlot {
                Image(systemName: "pin.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .opacity(isPinned ? 1 : 0)
                    .accessibilityHidden(!isPinned)
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
                    .frame(width: CloudTreeRowGrid.pinSlot)
            }
            content
        }
    }
}
