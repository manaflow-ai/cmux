/// The Mac page viewport: CSS size and the backing scale it renders at.
public struct BrowserPageGeometry: Hashable, Sendable {
    public var cssWidth: Double
    public var cssHeight: Double
    public var backingScale: Double

    public init(cssWidth: Double, cssHeight: Double, backingScale: Double) {
        self.cssWidth = cssWidth
        self.cssHeight = cssHeight
        self.backingScale = backingScale
    }
}
