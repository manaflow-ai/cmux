public import CoreGraphics
public import SwiftUI

/// Geometry for the floating peek panel.
///
/// The floating frame is the docked frame inset on three sides. Keeping the
/// list's own width identical across modes is deliberate: switching float and
/// dock should move the frame, not reflow the rows inside it, so the row a user
/// was reading stays the same shape.
public struct SidebarPeekPanelMetrics: Sendable, Equatable {
    /// Distance from the window's leading edge to the panel.
    public let leadingInset: CGFloat
    /// Distance from the window's top and bottom to the panel.
    public let verticalInset: CGFloat
    /// The panel's corner radius.
    public let cornerRadius: CGFloat
    /// Radius of the drop shadow.
    public let shadowRadius: CGFloat
    /// Vertical offset of the drop shadow.
    public let shadowOffsetY: CGFloat
    /// Opacity of the drop shadow.
    public let shadowOpacity: Double
    /// Width of the hairline border.
    public let borderWidth: CGFloat

    /// The shipped defaults.
    ///
    /// A 12pt radius against the row's 6pt keeps the card reading as a
    /// container for the rows rather than as one big row. The shadow is large
    /// and soft rather than tight and dark, so the panel separates from a
    /// terminal's arbitrary background without printing a hard edge on it.
    public static let `default` = SidebarPeekPanelMetrics(
        leadingInset: 8,
        verticalInset: 10,
        cornerRadius: 12,
        shadowRadius: 22,
        shadowOffsetY: 6,
        shadowOpacity: 0.34,
        borderWidth: 0.5
    )

    /// Creates panel metrics.
    public init(
        leadingInset: CGFloat,
        verticalInset: CGFloat,
        cornerRadius: CGFloat,
        shadowRadius: CGFloat,
        shadowOffsetY: CGFloat,
        shadowOpacity: Double,
        borderWidth: CGFloat
    ) {
        self.leadingInset = leadingInset
        self.verticalInset = verticalInset
        self.cornerRadius = cornerRadius
        self.shadowRadius = shadowRadius
        self.shadowOffsetY = shadowOffsetY
        self.shadowOpacity = shadowOpacity
        self.borderWidth = borderWidth
    }

    /// Hairline colour for the panel's edge.
    ///
    /// The card sits on an unknown background (whatever the terminal is
    /// showing), so the border is drawn from the panel's own side of the edge:
    /// a light inner rim in dark mode, a dark one in light mode.
    public func borderColor(isDark: Bool) -> Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.10)
    }
}
