import CoreGraphics

/// The right sidebar's chrome measurements, as the Cloud package sees them.
///
/// The app target owns `RightSidebarChromeMetrics`, and CmuxCloud cannot
/// import the app target, so every Cloud surface that sits inside the sidebar
/// has been carrying its own copy of these numbers. That is how the Cloud
/// banners ended up on a 12pt outer inset while the mode bar, the Vault
/// grouping pills and the Vault search row all sit on 8, and how the Cloud
/// tree ended up reserving a 12pt trailing column against the sidebar's 6.
///
/// These are the same numbers the app target uses. `CloudTreeLayoutMetricsTests`
/// runs in the app target, where both types are visible, and fails if the two
/// ever disagree, so the copy cannot drift silently.
///
/// Only package code should read this. Cloud views that live in the app target
/// have `RightSidebarChromeMetrics` in scope and use it directly.
///
/// These cover a bar's outer insets, not its full presentation: a real chrome
/// bar also takes a fixed height and scales with the global font setting, which
/// the Cloud banners still do not.
public enum CloudSidebarChromeMetrics {
    /// Outer horizontal inset of a sidebar chrome bar.
    public static let barHorizontalPadding: CGFloat = 8

    /// The trailing column the sidebar's *header* bars keep clear — narrower
    /// than the leading inset because the controls sitting in it are already
    /// inset by their own hit area. Tree row accessories pad to the same column
    /// so they line up with the header's controls above them rather than
    /// stopping short. A chrome bar without header controls stays on
    /// ``barHorizontalPadding``, which is why the Cloud banners do.
    public static let headerTrailingPadding: CGFloat = 6

    /// Outer vertical inset of a sidebar chrome bar.
    public static let barVerticalPadding: CGFloat = 4
}
