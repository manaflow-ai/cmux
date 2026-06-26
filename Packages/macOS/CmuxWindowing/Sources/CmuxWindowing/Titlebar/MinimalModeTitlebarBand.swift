public import AppKit

/// The clickable strip across the top of a minimal-mode window's content,
/// where a click is treated as a titlebar interaction.
///
/// A pure value type. The app target builds it from live window geometry and
/// asks whether a point lands in the band.
public struct MinimalModeTitlebarBand {
    /// Whether the band is active; a disabled band contains no point.
    public let isEnabled: Bool
    /// The content bounds the band sits at the top of.
    public let bounds: NSRect
    /// The band's height, measured down from `bounds.maxY`.
    public let topStripHeight: CGFloat

    /// Creates a titlebar band.
    public init(
        isEnabled: Bool,
        bounds: NSRect,
        topStripHeight: CGFloat
    ) {
        self.isEnabled = isEnabled
        self.bounds = bounds
        self.topStripHeight = topStripHeight
    }

    /// Reports whether `point` (in the same coordinate space as `bounds`) lands
    /// inside the band.
    public func contains(_ point: NSPoint) -> Bool {
        guard isEnabled, topStripHeight > 0, bounds.contains(point) else {
            return false
        }
        let clampedHeight = min(max(0, topStripHeight), bounds.height)
        return point.y >= bounds.maxY - clampedHeight
    }
}
