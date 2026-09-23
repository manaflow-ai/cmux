import CmuxFoundation
import SwiftUI

/// An unread badge in the leading identity column, followed by an optional pin.
/// Read rows keep the compact identity edge; unread rows reserve the badge slot.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool
    var attentionSlot: CGFloat = CloudTreeStyle.compact.rowGrid.attentionSlot
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    func body(content: Content) -> some View {
        // Keep read rows flush with the outline's content edge. A row earns the
        // leading slot only while it has unread attention, so the compact tree
        // does not carry an empty gutter between the caret and its identity.
        HStack(spacing: 2) {
            if showsAttentionSlot && hasUnreadNotification {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                    .help(String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification"))
                    .frame(width: GlobalFontMagnification.scaledSize(attentionSlot, percent: magnification))
                    .allowsHitTesting(false)
            }
            if isPinned {
                CmuxSystemSymbolImage(
                    magnified: "pin.fill",
                    pointSize: 9,
                    weight: .semibold,
                    tint: Color(nsColor: .secondaryLabelColor)
                )
                .fixedSize()
                .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
        }
    }
}
