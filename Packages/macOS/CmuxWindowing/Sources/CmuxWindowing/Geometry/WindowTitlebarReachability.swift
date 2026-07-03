public import CoreGraphics

/// Evaluates whether a window's top drag strip is reachable on a visible display.
public struct WindowTitlebarReachability: Sendable {
    private let thresholds: WindowTitlebarReachabilityThresholds

    /// Creates a reachability evaluator using `thresholds`.
    ///
    /// - Parameter thresholds: The visibility thresholds to apply.
    public init(thresholds: WindowTitlebarReachabilityThresholds) {
        self.thresholds = thresholds
    }

    /// Returns whether the top strip of `frame` is visible enough on a display.
    ///
    /// - Parameters:
    ///   - frame: Window frame in screen coordinates.
    ///   - visibleFrames: Visible display frames in the same coordinate space.
    /// - Returns: `true` when at least one visible frame exposes enough top strip.
    public func isTopStripReachable(
        _ frame: CGRect,
        onAnyOf visibleFrames: [CGRect]
    ) -> Bool {
        let standardized = frame.standardized
        guard standardized.width.isFinite,
              standardized.height.isFinite,
              standardized.width > 0,
              standardized.height > 0 else {
            return false
        }

        let stripHeight = min(thresholds.topStripHeight, standardized.height)
        let topStrip = CGRect(
            x: standardized.minX,
            y: standardized.maxY - stripHeight,
            width: standardized.width,
            height: stripHeight
        )
        let requiredWidth = min(thresholds.minimumVisibleWidth, standardized.width)
        let requiredHeight = min(thresholds.minimumVisibleHeight, stripHeight)

        for visibleFrame in visibleFrames {
            let visibleStrip = topStrip.intersection(visibleFrame)
            guard !visibleStrip.isNull else { continue }
            if visibleStrip.width >= requiredWidth, visibleStrip.height >= requiredHeight {
                return true
            }
        }
        return false
    }
}
