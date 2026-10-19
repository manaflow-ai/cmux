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
        // The columns over art are full height, so the whole height is visible.
        let x = Axis(view: vw, image: iw, subject: box.minX...box.maxX, span: span)
        let y = Axis(view: vh, image: ih, subject: box.minY...box.maxY, span: 0...vh)
        let check = (box: box, span: span, height: vh)

        let steps = 16
        for step in 0...steps {
            let scale = cover * (1 + (Self.maximumZoom - 1) * Double(step) / Double(steps))
            if let ox = x.covering(scale), let oy = y.covering(scale) {
                return place(scale: scale, origin: CGPoint(x: ox, y: oy), viewSize: viewSize, imageSize: imageSize, check: check)
            }
        }
        // The subject fits the span but not while the art covers the window, or only smaller:
        // the art slides (and shrinks) off an edge, which the panes over it mostly hide, over
        // the blurred fill.
        let fit = min((span.upperBound - span.lowerBound) / (iw * max(box.maxX - box.minX, 0.01)),
                      vh / (ih * max(box.maxY - box.minY, 0.01)), cover)
        if fit >= cover * Self.minimumShrink {
            return place(scale: fit, origin: CGPoint(x: x.shrunk(fit), y: y.shrunk(fit)), viewSize: viewSize, imageSize: imageSize,
                         check: check)
        }
        // Too big to keep whole: cover the window, centered on the subject across, its top kept.
        return place(scale: cover, origin: CGPoint(x: x.nearest(cover), y: y.nearest(cover, keepingLeading: true)),
                     viewSize: viewSize, imageSize: imageSize, check: check)
    }

    /// The subject box: the authored one, else a small box around the focal anchor.
    nonisolated var subject: BackdropSubjectBox { subjectBox ?? BackdropSubjectBox(around: focalAnchor) }

    /// The image at `scale` with its top-left corner at `origin` (top-left view coordinates).
    /// Whether the subject is kept is measured on the result, never assumed: its box must lie in
    /// the visible span across and in the window top to bottom.
    nonisolated func place(scale: Double, origin: CGPoint, viewSize: CGSize, imageSize: CGSize,
                                   check: (box: BackdropSubjectBox, span: ClosedRange<Double>, height: Double)) -> BackdropArtPlacement {
        let image = CGRect(x: origin.x, y: origin.y, width: Double(imageSize.width) * scale, height: Double(imageSize.height) * scale)
        let slack = 0.5
        let keeps = image.minX + check.box.minX * image.width >= check.span.lowerBound - slack
            && image.minX + check.box.maxX * image.width <= check.span.upperBound + slack
            && image.minY + check.box.minY * image.height >= -slack
            && image.minY + check.box.maxY * image.height <= check.height + slack
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

    /// The origin that centers the subject in the span.
    func centered(_ scale: Double) -> Double {
        (span.lowerBound + span.upperBound) / 2 - (subject.lowerBound + subject.upperBound) / 2 * image * scale
    }

    /// The origins at which the subject lies in the span (empty when it is wider).
    func keeping(_ scale: Double) -> ClosedRange<Double>? {
        let extent = image * scale
        let low = span.lowerBound - subject.lowerBound * extent, high = span.upperBound - subject.upperBound * extent
        return low <= high + 1e-6 ? low...max(low, high) : nil
    }

    /// The origin, nearest centered, at which the image covers the view and the subject lies in
    /// the span; nil when there is none.
    func covering(_ scale: Double) -> Double? {
        guard let keeps = keeping(scale) else { return nil }
        let low = max(view - image * scale, keeps.lowerBound), high = min(0, keeps.upperBound)
        guard low <= high + 1e-6 else { return nil }
        return min(max(centered(scale), low), max(low, high))
    }

    /// The origin at which the image covers the view: nearest centered, or with
    /// `keepingLeading` with the subject's leading edge (its top) in the span.
    func nearest(_ scale: Double, keepingLeading: Bool = false) -> Double {
        let wanted = keepingLeading && image * scale * (subject.upperBound - subject.lowerBound) > span.upperBound - span.lowerBound
            ? span.lowerBound - subject.lowerBound * image * scale : centered(scale)
        return min(max(wanted, view - image * scale), 0)
    }

    /// The origin for an image shrunk so the subject fits the span: the subject in the span
    /// first, then as much of the view covered, then centered.
    func shrunk(_ scale: Double) -> Double {
        let extent = image * scale
        guard let keeps = keeping(scale) else { return nearest(scale, keepingLeading: true) }
        let centered = min(max(centered(scale), keeps.lowerBound), keeps.upperBound)
        // Toward covering, as far as the subject allows: an image wider than the view slides
        // only as far as its edges reach the view's.
        let covering = extent >= view ? min(max(centered, view - extent), 0) : centered
        return min(max(covering, keeps.lowerBound), keeps.upperBound)
    }
}
