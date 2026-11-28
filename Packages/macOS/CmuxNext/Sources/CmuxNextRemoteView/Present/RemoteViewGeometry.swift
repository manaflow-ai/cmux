public import CoreGraphics

/// Where the stream image sits in the pane, and the mapping from pane
/// points to stream pixels. One stream pixel is one device pixel: the image
/// is never scaled. A smaller frame is centered with padding; on an axis
/// where the frame is larger than the pane, the image aligns to the top or
/// left edge (the remote menu bar and window titles stay visible) and the
/// rest is clipped until the host answers the resize (section 7, HiDPI).
/// Coordinates are flipped (origin top left), like stream pixels.
public nonisolated struct RemoteViewGeometry: Sendable, Equatable {
    public var framePixels: CGSize
    public var bounds: CGRect
    public var backingScale: CGFloat

    public init(framePixels: CGSize, bounds: CGRect, backingScale: CGFloat) {
        self.framePixels = framePixels
        self.bounds = bounds
        self.backingScale = max(backingScale, 1)
    }

    /// The image's frame in pane points, origins on device pixels.
    public var imageRect: CGRect {
        let size = CGSize(width: framePixels.width / backingScale, height: framePixels.height / backingScale)
        let x = size.width <= bounds.width ? bounds.minX + (bounds.width - size.width) / 2 : bounds.minX
        let y = size.height <= bounds.height ? bounds.minY + (bounds.height - size.height) / 2 : bounds.minY
        return CGRect(x: snap(x), y: snap(y), width: size.width, height: size.height)
    }

    /// The pixel the pane point falls on, or nil in the padding.
    public func streamPixel(at point: CGPoint) -> (x: Int32, y: Int32)? {
        let rect = imageRect
        guard rect.contains(point), framePixels.width >= 1, framePixels.height >= 1 else { return nil }
        return clampedStreamPixel(at: point)
    }

    /// The nearest stream pixel, clamped to the frame: a drag that leaves
    /// the image keeps reporting the edge, so a remote drag does not stick.
    public func clampedStreamPixel(at point: CGPoint) -> (x: Int32, y: Int32) {
        let rect = imageRect
        let px = ((point.x - rect.minX) * backingScale).rounded(.down)
        let py = ((point.y - rect.minY) * backingScale).rounded(.down)
        let maxX = max(framePixels.width - 1, 0)
        let maxY = max(framePixels.height - 1, 0)
        return (Int32(min(max(px, 0), maxX)), Int32(min(max(py, 0), maxY)))
    }

    /// The pane point at the center of stream pixel (x, y): the remote
    /// cursor overlay draws there.
    public func panePoint(forStreamPixel x: Double, _ y: Double) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + x / backingScale, y: rect.minY + y / backingScale)
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        (value * backingScale).rounded() / backingScale
    }
}
