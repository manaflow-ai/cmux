import CmuxMobileShellModel
import SwiftUI

/// The single unread indicator for workspace rows: an accent badge showing the
/// exact unread count (parity with the Mac sidebar's workspace unread badge),
/// in a fixed-width gutter to the LEFT of the workspace icon. Against a Mac
/// old enough not to report the count, it falls back to the original
/// iMessage-style dot.
///
/// Every row renders this gutter (the indicator is just hidden when read), so
/// read and unread rows keep their icon and text columns aligned. Shared by
/// the flat workspace list and the group headers; any future surface that
/// marks a workspace unread should reuse it rather than invent another badge.
struct WorkspaceUnreadDot: View {
    /// Width every row reserves for the indicator column, kept narrow so the
    /// list does not drift right. Indicators are LEADING-aligned in it: the
    /// badge is wider than the dot, and anchoring both to the same left edge
    /// keeps the leading margin identical whether a row shows a dot, a badge,
    /// or nothing. All overflow goes toward the rail, which `WorkspaceRow`'s
    /// layout math reserves via `badgeDiameter`.
    static let gutterWidth: CGFloat = 10
    /// Diameter of the count-less fallback dot.
    static let dotDiameter: CGFloat = 11
    /// Diameter of the count badge, matching the Mac sidebar badge's 16pt
    /// side. Fixed like the Mac's: multi-digit counts scale their text down
    /// rather than widening the circle, so columns never shift.
    static let badgeDiameter: CGFloat = 16

    let unread: MobileWorkspaceUnreadState
    var leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift

    init(unread: MobileWorkspaceUnreadState, leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift) {
        self.unread = unread
        self.leftShift = leftShift
    }

    init(isUnread: Bool, leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift) {
        self.init(
            unread: MobileWorkspaceUnreadState(isUnread: isUnread, count: nil),
            leftShift: leftShift
        )
    }

    private var badgeCount: Int? {
        guard unread.isUnread, let count = unread.count, count > 0 else { return nil }
        return count
    }

    var body: some View {
        ZStack {
            if let badgeCount {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: Self.badgeDiameter, height: Self.badgeDiameter)
                Text("\(badgeCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: Self.badgeDiameter - 3)
            } else {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: Self.dotDiameter, height: Self.dotDiameter)
                    .opacity(unread.isUnread ? 1 : 0)
            }
        }
        // One fixed badge-sized box for every indicator kind: the dot centers
        // in it, so dot rows and badge rows share the same indicator center
        // while the box's leading edge pins the margin.
        .frame(width: Self.badgeDiameter, height: Self.badgeDiameter)
        .frame(width: Self.gutterWidth, alignment: .leading)
        .offset(x: -CGFloat(leftShift))
        // The indicator is decorative here; rows fold the unread state into
        // their combined accessibility summary instead.
        .accessibilityHidden(true)
    }
}
