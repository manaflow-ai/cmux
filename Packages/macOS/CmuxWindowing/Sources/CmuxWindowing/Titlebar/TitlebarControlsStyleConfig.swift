public import SwiftUI

/// The resolved visual geometry for one titlebar-controls style: spacing,
/// glyph and button sizes, the notification badge size and offset, and the
/// group/button background and corner treatments.
///
/// A pure value type holding only its layout constants. The app target builds
/// an instance per `TitlebarControlsStyle` and derives every downstream
/// geometry (content size, hint intervals, offsets) from these stored values
/// through extensions that remain app-side because they reach into app-only
/// chrome metrics and debug settings. Nothing here has live coupling, so the
/// configuration can be passed freely across the views that render the controls.
public struct TitlebarControlsStyleConfig: Sendable {
    /// Horizontal gap between adjacent control buttons.
    public let spacing: CGFloat
    /// Point size of the control glyphs.
    public let iconSize: CGFloat
    /// Edge length of each square control button.
    public let buttonSize: CGFloat
    /// Diameter of the notification unread-count badge.
    public let badgeSize: CGFloat
    /// Offset of the badge from the button's top-trailing corner.
    public let badgeOffset: CGSize
    /// Whether the control group draws a rounded background container.
    public let groupBackground: Bool
    /// Inset applied around the control row inside its group.
    public let groupPadding: EdgeInsets
    /// Whether each button draws its own rounded background fill.
    public let buttonBackground: Bool
    /// Corner radius of a button's background/border.
    public let buttonCornerRadius: CGFloat
    /// Whether the controls react to pointer hover for this style.
    public let hoverBackground: Bool

    /// Creates a style configuration from its resolved layout constants.
    public init(
        spacing: CGFloat,
        iconSize: CGFloat,
        buttonSize: CGFloat,
        badgeSize: CGFloat,
        badgeOffset: CGSize,
        groupBackground: Bool,
        groupPadding: EdgeInsets,
        buttonBackground: Bool,
        buttonCornerRadius: CGFloat,
        hoverBackground: Bool
    ) {
        self.spacing = spacing
        self.iconSize = iconSize
        self.buttonSize = buttonSize
        self.badgeSize = badgeSize
        self.badgeOffset = badgeOffset
        self.groupBackground = groupBackground
        self.groupPadding = groupPadding
        self.buttonBackground = buttonBackground
        self.buttonCornerRadius = buttonCornerRadius
        self.hoverBackground = hoverBackground
    }
}
