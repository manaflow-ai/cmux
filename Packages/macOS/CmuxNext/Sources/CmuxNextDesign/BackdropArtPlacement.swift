public import Foundation

/// Where a painting's subject is: a normalized box in the artwork, measured from the top-left
/// corner, that the window should keep whole and in view (the faces, the ship, the vase).
public nonisolated struct BackdropSubjectBox: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double

    public nonisolated init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let clamp = { (value: Double, fallback: Double) in min(max(value.isFinite ? value : fallback, 0), 1) }
        let x0 = clamp(minX, 0), x1 = clamp(maxX, 1), y0 = clamp(minY, 0), y1 = clamp(maxY, 1)
        self.minX = min(x0, x1)
        self.maxX = max(x0, x1)
        self.minY = min(y0, y1)
        self.maxY = max(y0, y1)
    }

    /// A small box around a focal point, for art that names only a point.
    public nonisolated init(around anchor: BackdropFocalAnchor, width: Double = 0.2, height: Double = 0.3) {
        self.init(minX: anchor.x - width / 2, minY: anchor.y - height / 2, maxX: anchor.x + width / 2, maxY: anchor.y + height / 2)
    }

    public nonisolated var center: BackdropFocalAnchor { .init(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
}

/// How the art lies in the window: the part of the image shown (`contentsRect`, bottom-left
/// origin as Core Animation reads it) and the part of the view it fills (bottom-left origin, in
/// view points). The frame is the whole view unless the art had to shrink to keep its subject
/// whole, and then ``fills`` asks for the blurred fill behind it.
public nonisolated struct BackdropArtPlacement: Equatable, Sendable {
    public var contentsRect: CGRect
    public var frame: CGRect
    /// The art does not cover the view: a blurred copy fills the rest.
    public var fills: Bool
    /// The subject lies wholly in the visible span.
    public var keepsSubject: Bool

    /// The whole image over the whole view.
    public nonisolated static func whole(_ viewSize: CGSize) -> Self {
        .init(contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), frame: CGRect(origin: .zero, size: viewSize),
              fills: false, keepsSubject: true)
    }
}

/// The horizontal part of a window the art can be seen in: the window less the sidebar and the
/// agent chat column, which sit over the art (Leo, 2026-10-18: "the left pane is the
/// working/agent pane typically"). Fractions of the view's width.
public nonisolated struct BackdropVisibleSpan: Equatable, Sendable {
    public let minX: Double
    public let maxX: Double

    public nonisolated init(minX: Double, maxX: Double) {
        let x0 = min(max(minX.isFinite ? minX : 0, 0), 1), x1 = min(max(maxX.isFinite ? maxX : 1, 0), 1)
        self.minX = min(x0, x1)
        self.maxX = max(x0, x1)
    }

    public static let whole = Self(minX: 0, maxX: 1)

    /// A span narrower than this is no place for a subject: the art centers in the window then.
    public static let narrowest = 0.35

    /// The widest stretch of `width` that no obstruction covers. Obstructions are x ranges in
    /// view points (a column: the sidebar, a docked agent chat). Falls back to the whole width
    /// when what is left is too narrow to frame a subject in.
    public nonisolated static func uncovered(width: CGFloat, by obstructions: [ClosedRange<CGFloat>]) -> Self {
        guard width > 0 else { return .whole }
        var gaps: [ClosedRange<CGFloat>] = []
        var start: CGFloat = 0
        let clamped = obstructions.map { range -> ClosedRange<CGFloat> in
            let low = min(max(range.lowerBound, 0), width)
            return low...min(max(range.upperBound, low), width)
        }
        for range in clamped.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if range.lowerBound > start { gaps.append(start...range.lowerBound) }
            start = max(start, range.upperBound)
        }
        if start < width { gaps.append(start...width) }
        guard let widest = gaps.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }),
              Double((widest.upperBound - widest.lowerBound) / width) >= narrowest else { return .whole }
        return .init(minX: Double(widest.lowerBound / width), maxX: Double(widest.upperBound / width))
    }
}

extension BackdropArtMetadata {
    /// How far past a cover fit the art may zoom in to keep its subject in view: past this the
    /// 1600-pixel art goes soft.
    public nonisolated static let maximumZoom = 1.4
    /// How far below a cover fit the art may shrink (over its blurred fill) to keep its subject
    /// whole; past this it covers the window and lets the subject's edges go.
    public nonisolated static let minimumShrink = 0.7

    /// Places the art in a view of `viewSize` so its subject sits whole in the `visible` span:
    /// the least zoom that does it, the subject centered in the span as far as the edges allow.
    /// When no zoom up to ``maximumZoom`` does, it shrinks the art (down to ``minimumShrink``)
    /// over a blurred fill; when even that cannot, it covers the window around the subject.
    public nonisolated func placement(forViewSize viewSize: CGSize, imageSize: CGSize,
                                      visible: BackdropVisibleSpan = .whole) -> BackdropArtPlacement {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .whole(viewSize)
        }
        let box = subject
        let (vw, vh) = (Double(viewSize.width), Double(viewSize.height))
        let (iw, ih) = (Double(imageSize.width), Double(imageSize.height))
        let span = (visible.minX * vw)...(visible.maxX * vw)
        let cover = max(vw / iw, vh / ih)
        let x = Axis(view: vw, image: iw, subject: box.minX...box.maxX, span: span)
        // The columns over art are full height, so the whole height is visible. A subject taller
        // than the window (a portrait in a wide, short window) keeps its top: the faces.
        let y = Axis(view: vh, image: ih, subject: box.minY...box.maxY, span: 0...vh, keepsTop: true)

        let steps = 16
        for step in 0...steps {
            let scale = cover * (1 + (Self.maximumZoom - 1) * Double(step) / Double(steps))
            if let ox = x.covering(scale), let oy = y.covering(scale) {
                return place(scale: scale, origin: CGPoint(x: ox, y: oy), viewSize: viewSize, imageSize: imageSize, keeps: true)
            }
        }
        // The subject fits the span but not while the art covers the window, or only smaller:
        // the art slides (and shrinks) off an edge, which the panes over it mostly hide, over
        // the blurred fill.
        let fit = min((span.upperBound - span.lowerBound) / (iw * max(box.maxX - box.minX, 0.01)), cover)
        if fit >= cover * Self.minimumShrink {
            let oy = fit == cover ? y.covering(fit) ?? y.nearest(fit) : y.shrunk(fit)
            return place(scale: fit, origin: CGPoint(x: x.shrunk(fit), y: oy), viewSize: viewSize, imageSize: imageSize, keeps: true)
        }
        return place(scale: cover, origin: CGPoint(x: x.nearest(cover), y: y.nearest(cover)),
                     viewSize: viewSize, imageSize: imageSize, keeps: false)
    }

    /// The subject box: the authored one, else a small box around the focal anchor.
    nonisolated var subject: BackdropSubjectBox { subjectBox ?? BackdropSubjectBox(around: focalAnchor) }

    /// The image at `scale` with its top-left corner at `origin` (top-left view coordinates).
    private nonisolated func place(scale: Double, origin: CGPoint, viewSize: CGSize, imageSize: CGSize,
                                   keeps: Bool) -> BackdropArtPlacement {
        let image = CGRect(x: origin.x, y: origin.y, width: Double(imageSize.width) * scale, height: Double(imageSize.height) * scale)
        let shown = image.intersection(CGRect(origin: .zero, size: viewSize))
        guard !shown.isNull, shown.width > 0, shown.height > 0 else { return .whole(viewSize) }
        // Normalized in the image, then flipped: contentsRect and the view frame count from the bottom.
        let left = (shown.minX - image.minX) / image.width
        let top = (shown.minY - image.minY) / image.height
        let contents = CGRect(x: left, y: 1 - top - shown.height / image.height,
                              width: shown.width / image.width, height: shown.height / image.height)
        let frame = CGRect(x: shown.minX, y: viewSize.height - shown.maxY, width: shown.width, height: shown.height)
        let covers = shown.width >= viewSize.width - 0.5 && shown.height >= viewSize.height - 0.5
        return .init(contentsRect: contents, frame: covers ? CGRect(origin: .zero, size: viewSize) : frame,
                     fills: !covers, keepsSubject: keeps)
    }
}

/// One axis of ``BackdropArtMetadata/placement(forViewSize:imageSize:visible:)``: where the image's
/// leading edge may sit, in view points, for a scale.
private nonisolated struct Axis {
    let view: Double
    let image: Double
    let subject: ClosedRange<Double>
    let span: ClosedRange<Double>
    /// A subject too big for the span keeps its leading edge (the top) instead of failing.
    let keepsTop: Bool

    init(view: Double, image: Double, subject: ClosedRange<Double>, span: ClosedRange<Double>, keepsTop: Bool = false) {
        self.view = view
        self.image = image
        self.subject = subject
        self.span = span
        self.keepsTop = keepsTop
    }

    /// The origin that centers the subject in the span.
    func centered(_ scale: Double) -> Double {
        (span.lowerBound + span.upperBound) / 2 - (subject.lowerBound + subject.upperBound) / 2 * image * scale
    }

    /// The origin, nearest centered, at which the image covers the view and the subject lies in
    /// the span; nil when there is none.
    func covering(_ scale: Double) -> Double? {
        let extent = image * scale
        let low = max(view - extent, span.lowerBound - subject.lowerBound * extent)
        let high = min(0, span.upperBound - subject.upperBound * extent)
        guard low <= high + 1e-6 else {
            guard keepsTop else { return nil }
            return min(max(span.lowerBound - subject.lowerBound * extent, view - extent), 0)
        }
        return min(max(centered(scale), low), max(low, high))
    }

    /// The origin, nearest centered, at which the image still covers the view.
    func nearest(_ scale: Double) -> Double {
        min(max(centered(scale), view - image * scale), 0)
    }

    /// The origin for a shrunk image: the subject in the span, and as little empty view as that allows.
    func shrunk(_ scale: Double) -> Double {
        let extent = image * scale
        let low = span.lowerBound - subject.lowerBound * extent
        let high = span.upperBound - subject.upperBound * extent
        let centered = min(max(centered(scale), low), max(low, high))
        // Toward covering: an image wider than the view keeps both edges filled when it can.
        if extent >= view { return min(max(centered, max(low, view - extent)), min(max(low, high), 0)) }
        return centered
    }
}
