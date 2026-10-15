import CmuxCloud
import CmuxFoundation
import SwiftUI

/// An unread badge in the leading identity column, followed by an optional pin.
/// Read rows keep the compact identity edge; unread rows reserve the badge slot.
/// Immutable input keeps AppKit cell reuse independent of observable stores.
struct CloudSidebarRowDecoration: ViewModifier {
    @Environment(\.cmuxAccentColor) private var cmuxAccent
    let isPinned: Bool
    let showsAttentionSlot: Bool
    let hasUnreadNotification: Bool
    /// A terminal here reports a failed run: the slot shows the amber
    /// attention dot (the tree's color for "needs you") instead of the blue
    /// unread dot, even after the notification is read when the exit itself
    /// failed.
    var reportsFailure = false
    var attentionSlot: CGFloat = CloudTreeStyle.compact.rowGrid.attentionSlot
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var magnification

    func body(content: Content) -> some View {
        // Keep read rows flush with the outline's content edge. A row earns the
        // leading slot only while it has unread attention, so the compact tree
        // does not carry an empty gutter between the caret and its identity.
        HStack(spacing: 2) {
            if showsAttentionSlot && (hasUnreadNotification || reportsFailure) {
                Circle()
                    .fill(reportsFailure ? CloudTreeIconPalette.attention : cmuxAccent.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(attentionLabel)
                    .help(attentionLabel)
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
                // Machine rows have no icon after the pin, so the pin keeps
                // its own gap before the name.
                .padding(.trailing, GlobalFontMagnification.scaledSize(3, percent: magnification))
                .accessibilityLabel(String(localized: "taskManager.row.pinned", defaultValue: "Pinned"))
            }
            content
        }
    }

    private var attentionLabel: String {
        reportsFailure
            ? String(localized: "cloudTree.organization.failure", defaultValue: "An agent reported an error")
            : String(localized: "cloudTree.organization.unread", defaultValue: "Unread notification")
    }
}
