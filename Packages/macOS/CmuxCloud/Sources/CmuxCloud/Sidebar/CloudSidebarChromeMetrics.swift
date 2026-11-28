import CoreGraphics

/// The right sidebar's chrome measurements, as the Cloud package sees them.
///
/// The app target owns `RightSidebarChromeMetrics`, and CmuxCloud cannot
/// import the app target, so every Cloud surface that sits inside the sidebar
/// has been carrying its own copy of these numbers. That is how the Cloud
/// banners ended up on a 12pt outer inset, and the Cloud tree on a 12pt
/// trailing column, while the chrome bar they sit under takes 8 on both edges.
/// The sidebar's own header bars (the mode bar, the Vault grouping pills and
/// the Vault search row) ask for a narrower 4/6 instead, but the Cloud header
/// does not: it uses a plain `rightSidebarChromeBar()` and so keeps the 8.
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
///
/// ``sidebar`` holds the numbers the app ships. A surface that needs different
/// ones builds its own value rather than mutating shared state.
public struct CloudSidebarChromeMetrics: Equatable, Sendable {
    /// The right sidebar's chrome, as the app target defines it.
    public static let sidebar = CloudSidebarChromeMetrics()

    /// Outer horizontal inset of a sidebar chrome bar.
    public var barHorizontalPadding: CGFloat

    /// Outer vertical inset of a sidebar chrome bar.
    public var barVerticalPadding: CGFloat

    public init(
        barHorizontalPadding: CGFloat = 8,
        barVerticalPadding: CGFloat = 4
    ) {
        self.barHorizontalPadding = barHorizontalPadding
        self.barVerticalPadding = barVerticalPadding
    }
}
