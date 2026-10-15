import Foundation

/// A Chromium page zoom level, the logarithmic scale Chromium uses: factor = 1.2 ^ level.
///
/// cmux panels speak zoom factors (`1.0` is 100%, as `WKWebView.pageZoom` and the
/// `browser.defaultZoomLevel` setting do); a Chromium page takes and reports levels. This value
/// converts between the two so both engines share the panel's zoom model.
///
/// ```swift
/// BrowserChromiumZoomLevel(factor: 1.2).level      // 1.0
/// BrowserChromiumZoomLevel(level: -1).factor       // 0.8333…
/// ```
public struct BrowserChromiumZoomLevel: Hashable, Sendable {
    /// The Chromium zoom level; `0` is 100%.
    public let level: Double

    /// Creates a level value.
    /// - Parameter level: The Chromium level. A non-finite level means 100%.
    public init(level: Double) {
        self.level = level.isFinite ? level : 0
    }

    /// Creates the level for a zoom factor.
    /// - Parameter factor: The zoom factor; a non-positive or non-finite factor means 100%.
    public init(factor: Double) {
        guard factor > 0, factor.isFinite else {
            self.level = 0
            return
        }
        self.level = log(factor) / log(1.2)
    }

    /// The zoom factor for this level.
    public var factor: Double { pow(1.2, level) }
}
