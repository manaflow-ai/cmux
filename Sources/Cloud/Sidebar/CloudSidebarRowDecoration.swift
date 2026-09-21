import SwiftUI

/// An optional leading pin and an unread badge in the row's trailing padding.
/// Read/unread changes never move the row's icon or title.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool
    var trailingPadding: CGFloat = CloudTreeStyle.compact.rowGrid.trailingPadding

    func body(content: Content) -> some View {
        // Keep the pin in the same compact leading cluster as the row icon.
        HStack(spacing: 2) {
            if isPinned {
                Image(systemName: "pin.fill")
                    .cmuxFont(size: 9, weight: .semibold)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
                .overlay(alignment: .trailing) {
                    if showsAttentionSlot {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .opacity(hasUnreadNotification ? 1 : 0)
                            .accessibilityHidden(!hasUnreadNotification)
                            .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                            .help(hasUnreadNotification
                                ? String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification") : "")
                            // The leaf row already reserves trailing padding for
                            // its edge. Center the indicator in that space so it
                            // stays separate from text without consuming a new
                            // layout slot or colliding with hover controls.
                            .frame(width: trailingPadding)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}
