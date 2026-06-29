import SwiftUI

/// The single unread indicator for workspace rows: an iMessage-style accent
/// dot in a fixed-width gutter to the LEFT of the workspace icon.
///
/// Every row renders this gutter (the dot is just hidden when read), so read
/// and unread rows keep their icon and text columns aligned. Shared by the
/// flat workspace list and the device-tree workspace leaves; any future
/// surface that marks a workspace unread should reuse it rather than invent
/// another badge.
struct WorkspaceUnreadDot: View {
    /// Width every row reserves for the dot column, dot plus breathing room,
    /// kept narrow so the list does not drift right.
    static let gutterWidth: CGFloat = 10
    /// Diameter of the dot itself.
    static let dotDiameter: CGFloat = 11

    let isUnread: Bool
    var leftShift: Double = MobileDisplaySettings.defaultUnreadIndicatorLeftShift

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            .opacity(isUnread ? 1 : 0)
            .frame(width: Self.gutterWidth)
            .offset(x: -CGFloat(leftShift))
            // The dot is decorative here; rows fold the unread state into
            // their combined accessibility summary instead.
            .accessibilityHidden(true)
    }
}
