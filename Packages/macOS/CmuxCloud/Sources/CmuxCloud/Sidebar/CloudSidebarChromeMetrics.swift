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
public enum CloudSidebarChromeMetrics {
    /// Outer horizontal inset of a sidebar chrome bar.
    public static let barHorizontalPadding: CGFloat = 8

    /// Outer vertical inset of a sidebar chrome bar.
    public static let barVerticalPadding: CGFloat = 4

    /// The trailing column the sidebar's chrome bars keep clear. Row content
    /// pads to the same column so a row's accessories line up with the
    /// header's controls instead of stopping short of them.
    public static let headerTrailingPadding: CGFloat = 6
}
