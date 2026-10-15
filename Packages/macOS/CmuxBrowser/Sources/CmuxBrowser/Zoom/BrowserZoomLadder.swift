import Foundation

/// Chrome's page zoom presets and stepping rules (25% to 500%), used by Chromium panels for
/// Zoom In, Zoom Out and the zoom popover's − and + buttons.
///
/// A factor between presets steps to the next preset in the zoom direction, as Chrome does, so a
/// page restored at an odd factor rejoins the ladder on the first step.
///
/// ```swift
/// let ladder = BrowserZoomLadder()
/// ladder.zoomIn(from: 1.0)    // 1.1
/// ladder.zoomOut(from: 1.0)   // 0.9
/// ladder.zoomIn(from: 1.17)   // 1.25
/// ```
public struct BrowserZoomLadder: Hashable, Sendable {
    /// The preset factors, ascending (`chrome/common/page_zoom_constants.cc`).
    public let levels: [Double]

    /// Creates a ladder.
    /// - Parameter levels: Ascending preset factors. Defaults to Chrome's presets. An empty list
    ///   falls back to the defaults.
    public init(levels: [Double] = BrowserZoomLadder.chromePresets) {
        self.levels = levels.isEmpty ? Self.chromePresets : levels.sorted()
    }

    /// Chrome's preset zoom factors.
    public static let chromePresets: [Double] = [
        0.25, 0.33, 0.5, 0.67, 0.75, 0.8, 0.9, 1.0,
        1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0, 4.0, 5.0,
    ]

    /// The smallest preset.
    public var minimum: Double { levels[0] }
    /// The largest preset.
    public var maximum: Double { levels[levels.count - 1] }

    /// The next preset above `factor`, or the maximum at the top.
    /// - Parameter factor: The current zoom factor.
    /// - Returns: The zoomed-in factor.
    public func zoomIn(from factor: Double) -> Double {
        guard factor.isFinite else { return 1 }
        return levels.first { $0 > factor + Self.tolerance } ?? maximum
    }

    /// The next preset below `factor`, or the minimum at the bottom.
    /// - Parameter factor: The current zoom factor.
    /// - Returns: The zoomed-out factor.
    public func zoomOut(from factor: Double) -> Double {
        guard factor.isFinite else { return 1 }
        return levels.last { $0 < factor - Self.tolerance } ?? minimum
    }

    /// `factor` clamped to the ladder's range (`1` for a non-finite factor).
    /// - Parameter factor: A zoom factor.
    /// - Returns: The clamped factor.
    public func clamp(_ factor: Double) -> Double {
        guard factor.isFinite else { return 1 }
        return min(max(factor, minimum), maximum)
    }

    /// The whole percentage shown for a factor, e.g. 1.25 gives 125.
    /// - Parameter factor: A zoom factor.
    /// - Returns: The rounded percentage.
    public static func percent(_ factor: Double) -> Int {
        guard factor.isFinite else { return 100 }
        return Int((factor * 100).rounded())
    }

    private static let tolerance = 0.001
}
