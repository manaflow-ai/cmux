public import SwiftUI

/// Pure value snapshot driving the browser panel's focus-flash ring: the accent
/// color, the current flash opacity, and the ring's corner radius and inset.
///
/// Every field is resolved app-side. The accent color comes from the app's
/// `cmuxAccentColor()`, the opacity is the panel's animated `@State`, and the
/// radius/inset come from the app-side `FocusFlashPattern` ring metrics, so the
/// ring renders here without reaching back into the app target.
public struct BrowserFocusFlashSnapshot: Sendable {
    /// Accent color the ring stroke and shadow use.
    public var accentColor: Color
    /// Current flash opacity (0 = invisible, animated by the panel).
    public var opacity: Double
    /// Corner radius of the flash ring.
    public var cornerRadius: Double
    /// Inset applied around the flash ring.
    public var inset: Double

    /// Creates the focus-flash snapshot from values resolved app-side.
    public init(
        accentColor: Color,
        opacity: Double,
        cornerRadius: Double,
        inset: Double
    ) {
        self.accentColor = accentColor
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.inset = inset
    }
}
