public import CoreGraphics

/// Where the stream image sits in the pane, and the mapping from pane
/// points to stream pixels. One stream pixel is one device pixel: the image
/// is never scaled. A smaller frame is centered with padding; on an axis
/// where the frame is larger than the pane, the image aligns to the top or
/// left edge (the remote menu bar and window titles stay visible) and the
/// rest is clipped until the host answers the resize (section 7, HiDPI).
/// Coordinates are flipped (origin top left), like stream pixels.
///
/// `.fit` is for sources whose frame size the pane cannot choose (an RFB
/// compatibility host keeps its own screen size): the image is scaled to fit
/// the pane, aspect preserved, and centered.
public nonisolated struct RemoteViewGeometry: Sendable, Equatable {
    public enum Scaling: Sendable, Equatable {
        /// One stream pixel per device pixel (`cmux.rd/1` sizes the frame to the pane).
        case native
        /// Aspect fit, up or down.
        case fit
    }

    public var framePixels: CGSize
    public var bounds: CGRect
    public var backingScale: CGFloat
    public var scaling: Scaling

    public init(framePixels: CGSize, bounds: CGRect, backingScale: CGFloat, scaling: Scaling = .native) {
        self.framePixels = framePixels
        self.bounds = bounds
        self.backingScale = max(backingScale, 1)
        self.scaling = scaling
    }

    /// The image's frame in pane points, origins on device pixels.
    public var imageRect: CGRect {
        if scaling == .fit, framePixels.width >= 1, framePixels.height >= 1, bounds.width > 0, bounds.height > 0 {
            let scale = min(bounds.width / framePixels.width, bounds.height / framePixels.height)
            let size = CGSize(width: framePixels.width * scale, height: framePixels.height * scale)
            return CGRect(x: snap(bounds.minX + (bounds.width - size.width) / 2),
                          y: snap(bounds.minY + (bounds.height - size.height) / 2),
                          width: size.width, height: size.height)
        }
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
        let px = ((point.x - rect.minX) * pixelsPerPoint(rect)).rounded(.down)
        let py = ((point.y - rect.minY) * pixelsPerPoint(rect)).rounded(.down)
        let maxX = max(framePixels.width - 1, 0)
        let maxY = max(framePixels.height - 1, 0)
        return (Int32(min(max(px, 0), maxX)), Int32(min(max(py, 0), maxY)))
    }

    /// The pane point at the center of stream pixel (x, y): the remote
    /// cursor overlay draws there.
    public func panePoint(forStreamPixel x: Double, _ y: Double) -> CGPoint {
        let rect = imageRect
        return CGPoint(x: rect.minX + x / pixelsPerPoint(rect), y: rect.minY + y / pixelsPerPoint(rect))
    }

    /// Stream pixels per pane point: the backing scale for `.native`.
    private func pixelsPerPoint(_ rect: CGRect) -> CGFloat {
        guard scaling == .fit, rect.width > 0 else { return backingScale }
        return framePixels.width / rect.width
    }

    private func snap(_ value: CGFloat) -> CGFloat {
        (value * backingScale).rounded() / backingScale
    }
}
