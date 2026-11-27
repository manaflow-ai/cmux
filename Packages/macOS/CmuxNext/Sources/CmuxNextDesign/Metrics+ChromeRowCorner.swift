public import CoreGraphics

/// Chrome's roundness on the window's one chrome row (Lawrence 2026-11-11: "same roundness as chrome"):
/// a tab pill, the omnibar and a sidebar workspace row are ``chromeRowHeight`` tall, and each rounds
/// as Chromium rounds its free-standing tab.
extension Metrics {
    /// Helium's corner on its tab and omnibar, on a row of `height`: 8 pt on its 28 pt tab pill and location bar
    /// (measured from 2x captures of Helium 0.21.3.1; tabs.patch and location-bar.patch round both 8), the same share of
    /// the row at every density, in whole points: 6 on 20, 8 on 28, 9 on 31, 10 on 34 (Lawrence 2026-11-13: Helium at
    /// Default, its shapes at every density). Was Chromium's vertical tab ratio, 8 on 30.
    public static func chromeRowCornerRadius(height: CGFloat) -> CGFloat { (height * 8 / 28).rounded() }

    /// Whether the person set the one outer corner radius (`layout.paneCornerRadius`, a Debug Settings
    /// override of `densityPaneCornerRadius`, or a custom density's token for it): then the tabs and
    /// the omnibar keep the concentric chain from that radius, not Chrome's ratio.
    public static var cornerRadiusIsSet: Bool {
        DesignSettings.shared.paneChrome.cornerRadius != nil || MetricTunables.densityPaneCornerRadius.explicitValue != nil
    }

    /// Chrome's tab radius applies: no radius the person set (``cornerRadiusIsSet``) and no Floating
    /// Panes, whose own cards the tabs stay concentric with.
    static var usesChromeRowCorner: Bool { !cornerRadiusIsSet && !floatingPanes }
}
