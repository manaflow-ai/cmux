public import CoreGraphics

/// Geometry constants for the header-chrome control buttons (size, glyph size,
/// corner radius, leading padding).
///
/// A pure constant table with no instance dimension. Kept as a caseless
/// namespace for the byte-identical lift; value-type redesign deferred.
// lint:allow namespace-type — faithful lift of the pre-existing app-target header-chrome control-metric constant table; value-type redesign is call-site-changing and deferred to a separate commit.
public enum HeaderChromeControlMetrics {
    /// Edge length of a square control button.
    public static let buttonSize: CGFloat = 20
    /// Point size of a control glyph.
    public static let iconSize: CGFloat = 12
    /// Edge length of the icon's framing box.
    public static let iconFrameSize: CGFloat = 14
    /// Corner radius of a control button's background.
    public static let cornerRadius: CGFloat = 6
    /// Leading padding before the titlebar controls row.
    public static let titlebarControlsLeadingPadding: CGFloat = 4

    /// The icon frame size for a given glyph point size, never smaller than the
    /// default frame.
    public static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        max(Self.iconFrameSize, iconSize + 2)
    }
}
