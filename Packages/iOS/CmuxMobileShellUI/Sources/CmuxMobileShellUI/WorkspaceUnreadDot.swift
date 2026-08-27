import CmuxMobileShellModel
import SwiftUI

/// The single unread indicator for workspace rows: an accent badge showing the
/// unread count (parity with the Mac sidebar's workspace unread badge, which
/// is always numeric), in a fixed-width gutter to the LEFT of the workspace
/// icon. Against a Mac old enough to report only the boolean, the badge shows
/// the minimum count that boolean implies (1) — never a count-less dot, so
/// marking a workspace unread reads "1" exactly like the Mac.
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
    let unread: MobileWorkspaceUnreadState
    var leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift
    var diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter

    init(
        unread: MobileWorkspaceUnreadState,
        leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.unread = unread
        self.leftShift = leftShift
        self.diameter = diameter
    }

    init(
        isUnread: Bool,
        leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift,
        diameter: Double = MobileDisplaySettings.defaultUnreadBadgeDiameter
    ) {
        self.init(
            unread: MobileWorkspaceUnreadState(isUnread: isUnread, count: nil),
            leftShift: leftShift,
            diameter: diameter
        )
    }

    /// The number the badge shows: the exact count when known, otherwise the
    /// minimum an unread boolean implies (1). A `0` from a skewed payload also
    /// clamps to 1 — an unread row must never render an empty circle.
    private var badgeCount: Int? {
        guard unread.isUnread else { return nil }
        return max(unread.count ?? 1, 1)
    }

    var body: some View {
        let side = CGFloat(diameter)
        ZStack {
            if let badgeCount {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: side, height: side)
                Text("\(badgeCount)")
                    .font(.system(size: side * 0.625, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(width: side - 3)
            }
        }
        // A fixed badge-sized box whose leading edge pins the margin; any
        // future indicator variant must center in it so every row shares one
        // indicator center.
        .frame(width: side, height: side)
        .frame(width: Self.gutterWidth, alignment: .leading)
        .offset(x: -CGFloat(leftShift))
        // The indicator is decorative here; rows fold the unread state into
        // their combined accessibility summary instead.
        .accessibilityHidden(true)
    }
}
