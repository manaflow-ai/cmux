public import CoreGraphics

/// Chrome geometry for minimal mode: the titlebar height it reserves.
///
/// A pure constant table with no instance dimension. Kept as a caseless
/// namespace for the byte-identical lift; value-type redesign deferred.
// lint:allow namespace-type — faithful lift of the pre-existing app-target minimal-mode chrome-metric constant; value-type redesign is call-site-changing and deferred to a separate commit.
public enum MinimalModeChromeMetrics {
    /// Titlebar height reserved in minimal mode.
    public static let titlebarHeight: CGFloat = WindowChromeMetrics.appTitlebarHeight
}
