public import CoreGraphics

/// What part of a canvas a screen shows: the canvas point at the center of
/// the viewport and the zoom (screen points per canvas point).
///
/// The camera is in canvas coordinates, so it does not depend on the
/// viewport: a window resize keeps the same point in the middle. The
/// visible rect for a viewport is ``visibleRect(viewport:)``; the screen view
/// uses it as its bounds (plans/cmux-next/canvas-layout.md, Drawing).
///
/// ```swift
/// let camera = CanvasCamera(center: CGPoint(x: 600, y: 400))
/// let closer = camera.zoomed(by: CanvasCamera.zoomStep)
/// ```
public nonisolated struct CanvasCamera: Hashable, Sendable {
    /// The zooms a camera can take.
    public static let zoomRange: ClosedRange<Double> = 0.1...3
    /// One Zoom In or Zoom Out step.
    public static let zoomStep = 1.25

    /// The canvas point shown at the center of the viewport.
    public var center: CGPoint
    /// Screen points per canvas point, inside ``zoomRange``.
    public var zoom: Double

    /// A camera at `center` with `zoom` (clamped to ``zoomRange``).
    public init(center: CGPoint = .zero, zoom: Double = 1) {
        self.center = center
        self.zoom = Self.clamped(zoom)
    }

    /// The canvas rect a viewport of `viewport` screen points shows.
    public func visibleRect(viewport: CGSize) -> CGRect {
        let width = viewport.width / zoom, height = viewport.height / zoom
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// The camera at `zoom` (clamped) with the canvas point `anchor` where it
    /// showed before; the center stays when `anchor` is nil.
    public func zoomed(to zoom: Double, around anchor: CGPoint? = nil) -> CanvasCamera {
        let next = Self.clamped(zoom)
        guard let anchor else { return CanvasCamera(center: center, zoom: next) }
        let keep = self.zoom / next
        return CanvasCamera(center: CGPoint(x: anchor.x - (anchor.x - center.x) * keep,
                                            y: anchor.y - (anchor.y - center.y) * keep), zoom: next)
    }

    /// ``zoomed(to:around:)`` at this zoom times `factor`.
    public func zoomed(by factor: Double, around anchor: CGPoint? = nil) -> CanvasCamera {
        zoomed(to: zoom * factor, around: anchor)
    }

    /// The camera moved so the canvas follows a pointer that moved `delta`
    /// screen points (a trackpad scroll's natural direction).
    public func panned(byScreenDelta delta: CGSize) -> CanvasCamera {
        CanvasCamera(center: CGPoint(x: center.x - delta.width / zoom, y: center.y - delta.height / zoom), zoom: zoom)
    }

    /// The camera moved the least that shows `rect` whole, `margin` screen
    /// points inside the viewport edges; an axis where it shows already does
    /// not move. A rect larger than the viewport shows its top-left corner.
    public func revealing(_ rect: CGRect, viewport: CGSize, margin: CGFloat) -> CanvasCamera {
        let visible = visibleRect(viewport: viewport), inset = margin / zoom
        let x = Self.reveal(min: rect.minX, max: rect.maxX, margin: inset, origin: visible.minX, length: visible.width)
        let y = Self.reveal(min: rect.minY, max: rect.maxY, margin: inset, origin: visible.minY, length: visible.height)
        return CanvasCamera(center: CGPoint(x: x + visible.width / 2, y: y + visible.height / 2), zoom: zoom)
    }

    /// The camera that shows all of `content` with `padding` screen points
    /// around it, never closer than zoom 1.
    public func fitting(_ content: CGRect, viewport: CGSize, padding: CGFloat) -> CanvasCamera {
        let width = viewport.width - padding * 2, height = viewport.height - padding * 2
        let center = CGPoint(x: content.midX, y: content.midY)
        guard content.width > 0, content.height > 0, width > 0, height > 0 else { return CanvasCamera(center: center, zoom: min(zoom, 1)) }
        return CanvasCamera(center: center, zoom: min(1, width / content.width, height / content.height))
    }

    private static func clamped(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return 1 }
        return min(max(zoom, zoomRange.lowerBound), zoomRange.upperBound)
    }

    /// The origin on one axis that shows `min...max` (classic `CanvasViewportMath`).
    private static func reveal(min lower: CGFloat, max upper: CGFloat, margin: CGFloat, origin: CGFloat, length: CGFloat) -> CGFloat {
        if lower >= origin, upper <= origin + length { return origin }
        let paddedMin = lower - margin, paddedMax = upper + margin
        let next: CGFloat
        if paddedMax - paddedMin >= length || paddedMin < origin {
            next = paddedMin
        } else {
            next = paddedMax - length
        }
        // A rect that fits without its margin still shows whole; the margin shrinks instead.
        guard upper - lower <= length else { return next }
        return Swift.min(Swift.max(next, upper - length), lower)
    }
}
