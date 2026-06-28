public import CoreGraphics

/// Shared height and clamp constants for the window-chrome bars (app titlebar,
/// bonsplit tab bar, secondary titlebar).
///
/// A pure constant table describing the fixed geometry of the window chrome. It
/// has no instance dimension, so it stays a caseless namespace; the value-type
/// redesign is deferred to a follow-up because every call site reads the
/// constants statically and changing that is behavior-neutral churn outside
/// this byte-identical lift.
// lint:allow namespace-type — faithful lift of the pre-existing app-target chrome-metric constant table; value-type redesign is call-site-changing and deferred to a separate commit.
public enum WindowChromeMetrics {
    /// Shared height for every chrome bar.
    public static let sharedChromeBarHeight: CGFloat = 28
    /// Height of the app titlebar.
    public static let appTitlebarHeight: CGFloat = sharedChromeBarHeight
    /// Height of the bonsplit tab bar.
    public static let bonsplitTabBarHeight: CGFloat = sharedChromeBarHeight
    /// Height of the secondary titlebar.
    public static let secondaryTitlebarHeight: CGFloat = sharedChromeBarHeight
    /// Minimum allowed titlebar height.
    public static let minimumTitlebarHeight: CGFloat = sharedChromeBarHeight
    /// Maximum allowed titlebar height.
    public static let maximumTitlebarHeight: CGFloat = 72
    /// Default titlebar height.
    public static let defaultTitlebarHeight: CGFloat = sharedChromeBarHeight

    /// Clamps a titlebar height into the allowed range.
    public static func clampedTitlebarHeight(_ height: CGFloat) -> CGFloat {
        max(minimumTitlebarHeight, min(maximumTitlebarHeight, height))
    }
}
