import CoreGraphics

/// Maps between the phone view and the streamed Mac page under fit and local zoom.
struct BrowserStreamTransform: Equatable, Sendable {
    /// The phone surface size.
    let viewSize: CGSize
    /// The streamed page viewport size in Mac points.
    let pageSize: CGSize
    /// Local lens zoom, clamped to at least one.
    let zoomScale: CGFloat
    /// Local viewport translation in phone-view points.
    let viewportOffset: CGPoint

    /// Creates transform math for a displayed frame.
    init(viewSize: CGSize, pageSize: CGSize, zoomScale: CGFloat = 1, viewportOffset: CGPoint = .zero) {
        self.viewSize = viewSize
        self.pageSize = pageSize
        self.zoomScale = max(1, zoomScale)
        self.viewportOffset = viewportOffset
    }

    /// Scale that fits the full streamed page width into the phone view.
    var fitScale: CGFloat {
        guard viewSize.width > 0, pageSize.width > 0 else { return 1 }
        return viewSize.width / pageSize.width
    }

    /// The page rectangle in view coordinates after fit, zoom, and local pan.
    var displayedPageRect: CGRect {
        let base = basePageRect
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let origin = CGPoint(
            x: center.x + (base.minX - center.x) * zoomScale - viewportOffset.x,
            y: center.y + (base.minY - center.y) * zoomScale - viewportOffset.y
        )
        return CGRect(
            origin: origin,
            size: CGSize(width: base.width * zoomScale, height: base.height * zoomScale)
        )
    }

    /// Converts a point in the phone view into the corresponding Mac page point.
    /// - Parameter point: A view-space point.
    /// - Returns: A page point clamped to the streamed viewport, or `nil` for invalid geometry.
    func pagePoint(fromViewPoint point: CGPoint) -> CGPoint? {
        let rect = displayedPageRect
        guard rect.width > 0, rect.height > 0,
              pageSize.width > 0, pageSize.height > 0,
              rect.contains(point) else { return nil }
        return CGPoint(
            x: min(max((point.x - rect.minX) / rect.width * pageSize.width, 0), pageSize.width),
            y: min(max((point.y - rect.minY) / rect.height * pageSize.height, 0), pageSize.height)
        )
    }

    /// Converts a Mac page point into the corresponding phone-view point.
    /// - Parameter point: A point in the streamed page viewport.
    /// - Returns: The view-space point, or `nil` for invalid geometry.
    func viewPoint(fromPagePoint point: CGPoint) -> CGPoint? {
        let rect = displayedPageRect
        guard rect.width > 0, rect.height > 0, pageSize.width > 0, pageSize.height > 0 else { return nil }
        return CGPoint(
            x: rect.minX + point.x / pageSize.width * rect.width,
            y: rect.minY + point.y / pageSize.height * rect.height
        )
    }

    /// Converts a view-space scroll delta to Mac page points at the current fit scale.
    /// - Parameter delta: A delta reported by the native scroll mechanics view.
    /// - Returns: The corresponding page-point delta.
    func pageDelta(fromViewDelta delta: CGPoint) -> CGPoint {
        let scale = max(fitScale, .leastNonzeroMagnitude)
        return CGPoint(x: delta.x / scale, y: delta.y / scale)
    }

    private var basePageRect: CGRect {
        let size = CGSize(width: pageSize.width * fitScale, height: pageSize.height * fitScale)
        return CGRect(
            x: (viewSize.width - size.width) / 2,
            y: (viewSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}
