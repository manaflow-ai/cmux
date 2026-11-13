public import CoreGraphics

/// Chrome's roundness on the window's one chrome row (Lawrence 2026-11-11: "same roundness as chrome"):
/// a tab pill, the omnibar and a sidebar workspace row are ``chromeRowHeight`` tall, and each rounds
/// as Chromium rounds its free-standing tab.
extension Metrics {
    /// Chromium's corner on a free-standing rounded-rect tab, on a tab of `height`: `kVerticalTabCornerRadius`
    /// 8 on a `kVerticalTabHeight` 30 tab (chrome/browser/ui/layout_constants.cc, chromium main f1b4f9c05eb7),
    /// the same ratio at every height, in whole points: 5 on 20, 6 on 24, 8 on 30, 9 on 34, 11 on 42.
    public static func chromeRowCornerRadius(height: CGFloat) -> CGFloat { (height * 8 / 30).rounded() }

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
