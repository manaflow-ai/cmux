public import CoreGraphics

/// Pure layout constants for the custom main-window chrome (titlebar band height,
/// content height). Mirrors the app-target `WindowChromeMetrics` values that the
/// moved window-chrome cluster reads; kept in the package so the chrome views and
/// `WindowChromeController` need no app-target dependency for these constants.
///
/// The values are byte-faithful to `WindowChromeMetrics.appTitlebarHeight` (28).
public enum WindowChromeLayoutMetrics {
    /// Height of the cmux custom titlebar band.
    public static let appTitlebarHeight: CGFloat = 28

    /// Default reported native titlebar inset before AppKit measures one.
    public static let defaultTitlebarHeight: CGFloat = 28

    /// Minimum clamp for a measured native titlebar height.
    public static let minimumTitlebarHeight: CGFloat = 28

    /// Maximum clamp for a measured native titlebar height.
    public static let maximumTitlebarHeight: CGFloat = 72

    /// Clamps a measured native titlebar height into the supported range.
    public static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}
