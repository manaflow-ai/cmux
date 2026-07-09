public import CoreGraphics
public import SwiftUI

/// The circular unread-count badge shown at the leading edge of a workspace
/// row's header.
///
/// Renders a filled circle with the unread count centered inside it. All colors
/// and sizing are resolved by the caller (the active/inverted-foreground ramp
/// and the configurable notification-badge color live in the owning row) and
/// passed in as values, so this package view holds no app-target color
/// dependency.
public struct SidebarWorkspaceUnreadBadge: View {
    let count: Int
    let fillColor: Color
    let textColor: Color
    let diameter: CGFloat
    let fontScale: CGFloat

    /// Creates the unread-count badge.
    /// - Parameters:
    ///   - count: The unread count to display.
    ///   - fillColor: Fill color for the badge circle.
    ///   - textColor: Foreground color for the count text.
    ///   - diameter: Width and height of the badge circle, in points.
    ///   - fontScale: Multiplier applied to the base count font size.
    public init(
        count: Int,
        fillColor: Color,
        textColor: Color,
        diameter: CGFloat,
        fontScale: CGFloat
    ) {
        self.count = count
        self.fillColor = fillColor
        self.textColor = textColor
        self.diameter = diameter
        self.fontScale = fontScale
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)
            Text("\(count)")
                .font(.system(size: 9 * fontScale, weight: .semibold))
                .foregroundColor(textColor)
        }
        .frame(width: diameter, height: diameter)
    }
}
