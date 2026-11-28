/// Maps a phone viewport report to the logical browser viewport used on macOS.
public struct MobileBrowserStreamViewportMapping: Equatable, Sendable {
    /// Reflow viewport in CSS points.
    public let viewport: BrowserViewport
    /// Validated phone backing scale carried by the report.
    public let phoneScale: Double

    /// Creates a mapping by clamping point dimensions to ``BrowserViewport`` limits.
    ///
    /// The phone scale does not multiply the logical dimensions. WebKit lays out in
    /// CSS points, while the Mac web view's backing scale controls capture pixels.
    /// - Parameters:
    ///   - width: Phone viewport width in CSS points.
    ///   - height: Phone viewport height in CSS points.
    ///   - scale: Phone display backing scale, which must be finite and positive.
    public init?(width: Int, height: Int, scale: Double) {
        guard scale.isFinite, scale > 0 else { return nil }
        let clampedWidth = min(
            max(width, BrowserViewport.minimumDimension),
            BrowserViewport.maximumDimension
        )
        let clampedHeight = min(
            max(height, BrowserViewport.minimumDimension),
            BrowserViewport.maximumDimension
        )
        guard let viewport = BrowserViewport(width: clampedWidth, height: clampedHeight) else {
            return nil
        }
        self.viewport = viewport
        self.phoneScale = scale
    }
}
