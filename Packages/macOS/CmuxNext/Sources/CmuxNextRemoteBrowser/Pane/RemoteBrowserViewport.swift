public import CoreGraphics

#if DEBUG
/// The page size a remote tab asks the host for (`rb.screen`, RT4): the
/// pane's size in CSS pixels at the pane's backing scale. CSS sizes are whole
/// points (the page sees integer `innerWidth`), so the pixel size is exact.
public nonisolated struct RemoteBrowserViewport: Sendable, Hashable {
    public let cssWidth: Int
    public let cssHeight: Int
    public let scale: CGFloat

    /// A zero or fractional pane rounds down to whole CSS pixels, never below
    /// one; an unknown scale is 1.
    public init(bounds: CGSize, backingScale: CGFloat) {
        cssWidth = max(1, Int(bounds.width.rounded(.down)))
        cssHeight = max(1, Int(bounds.height.rounded(.down)))
        scale = backingScale > 0 ? backingScale : 1
    }

    /// True when the pane had no area (no layout yet).
    public var isEmpty: Bool { false }

    public var pixelWidth: Int { Int((CGFloat(cssWidth) * scale).rounded()) }
    public var pixelHeight: Int { Int((CGFloat(cssHeight) * scale).rounded()) }
}
#endif
