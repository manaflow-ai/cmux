/// Terminal font size: the base size scaled by Dynamic Type, times the
/// user's pinch zoom (client view state, saved per device). Font size never
/// changes a host-locked grid; it changes how many cells fit (the viewport).
public struct TerminalFontSizing: Hashable, Sendable {
    /// Points at the default content size category (`.large`).
    public var baseSize: Double
    public var minimumSize: Double
    public var maximumSize: Double
    public var zoomRange: ClosedRange<Double>

    public init(baseSize: Double = 13, minimumSize: Double = 7, maximumSize: Double = 36,
                zoomRange: ClosedRange<Double> = 0.5...3) {
        self.baseSize = baseSize
        self.minimumSize = minimumSize
        self.maximumSize = max(minimumSize, maximumSize)
        self.zoomRange = zoomRange
    }

    /// - Parameters:
    ///   - dynamicTypeScale: the body text style's scale at the current
    ///     content size category (`UIFontMetrics.scaledValue(for: 1)`), 1 at `.large`.
    ///   - zoom: the pinch zoom, clamped to `zoomRange`.
    /// - Returns: points, clamped and rounded to half points so a slow pinch
    ///   does not rebuild the glyph atlas for every hundredth of a point.
    public func fontSize(dynamicTypeScale: Double, zoom: Double = 1) -> Double {
        let scale = dynamicTypeScale.isFinite && dynamicTypeScale > 0 ? dynamicTypeScale : 1
        let raw = baseSize * scale * clampedZoom(zoom)
        let clamped = min(max(raw, minimumSize), maximumSize)
        return (clamped * 2).rounded() / 2
    }

    /// The zoom after a pinch that started at `startZoom` and reached `pinchScale`.
    public func zoom(startZoom: Double, pinchScale: Double) -> Double {
        guard pinchScale.isFinite, pinchScale > 0 else { return clampedZoom(startZoom) }
        return clampedZoom(startZoom * pinchScale)
    }

    public func clampedZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }
}
