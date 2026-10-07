public import CoreGraphics

#if DEBUG
/// The page size a remote tab asks the host for (`rb.screen`, RT4): the
/// pane's size in CSS pixels at the pane's backing scale. CSS sizes are whole
/// points (the page sees integer `innerWidth`), so the pixel size is exact.
public nonisolated struct RemoteBrowserViewport: Sendable, Hashable {
    public let cssWidth: Int
    public let cssHeight: Int
    public let scale: CGFloat

    public init(bounds: CGSize, backingScale: CGFloat) {
        cssWidth = 0
        cssHeight = 0
        scale = 0
    }

    public var pixelWidth: Int { 0 }
    public var pixelHeight: Int { 0 }
}
#endif
