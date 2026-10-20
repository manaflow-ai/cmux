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
/// origin as Core Animation reads it) over the whole view (`frame`). The art always covers the
/// window at its own aspect, so no desktop, letterbox or blurred band shows beside it (Leo,
/// 2026-10-19: "it should resize better... it is able to fill more").
public nonisolated struct BackdropArtPlacement: Equatable, Sendable {
    public var contentsRect: CGRect
    public var frame: CGRect
    /// The subject lies wholly in the visible span.
    public var keepsSubject: Bool

    /// The whole image over the whole view.
    public nonisolated static func whole(_ viewSize: CGSize) -> Self {
        .init(contentsRect: CGRect(x: 0, y: 0, width: 1, height: 1), frame: CGRect(origin: .zero, size: viewSize),
              keepsSubject: true)
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
    /// Where down a side render's subject the window centers when it cannot show all of it.
    public nonisolated static let portraitAnchor = 1.0 / 3

    /// Places the art so it covers a view of `viewSize` (aspect fill, never letterboxed or
    /// shrunk): of a side render only its ``panel``, the painting, never the blurred fill beside
    /// it. Within that cover the subject sits whole in the `visible` span with the least zoom
    /// (up to ``maximumZoom``) that does it, centered in the span as far as the edges allow; when
    /// no zoom does, the art covers the window centered on the subject across, and down with its
    /// top kept (a side render: its upper third, ``portraitAnchor``).
    public nonisolated func placement(forViewSize viewSize: CGSize, imageSize: CGSize,
                                      visible: BackdropVisibleSpan = .whole) -> BackdropArtPlacement {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else {
            return .whole(viewSize)
        }
        let panel = self.panel ?? BackdropSubjectBox(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let (vw, vh) = (Double(viewSize.width), Double(viewSize.height))
        // The painting's part of the image, in image pixels: the art is laid out as if it were all.
        let (pw, ph) = (Double(imageSize.width) * max(panel.maxX - panel.minX, 0.01),
                        Double(imageSize.height) * max(panel.maxY - panel.minY, 0.01))
        let box = subject(in: panel)
        let span = (visible.minX * vw)...(visible.maxX * vw)
        let cover = max(vw / pw, vh / ph)
        // The columns over art are full height, so the whole height is visible.
        let x = Axis(view: vw, image: pw, subject: box.minX...box.maxX, span: span)
        let y = Axis(view: vh, image: ph, subject: box.minY...box.maxY, span: 0...vh)

        let steps = 16
        for step in 0...steps {
            let scale = cover * (1 + (Self.maximumZoom - 1) * Double(step) / Double(steps))
            if let ox = x.covering(scale), let oy = y.covering(scale) {
                return place(scale: scale, origin: (ox, oy), painting: (pw, ph), panel: panel, box: box, viewSize: viewSize, span: span)
            }
        }
        // Too big to keep whole in the span: cover the window, centered on the subject across, its
        // top kept. A side render's subject is the whole tall painting, so there the window centers
        // on its upper third, where a portrait's face is: its top is the sky or the hat.
        let oy = self.panel == nil ? y.nearest(cover, keepingLeading: true) : y.nearest(cover, at: Self.portraitAnchor)
        return place(scale: cover, origin: (x.nearest(cover), oy), painting: (pw, ph),
                     panel: panel, box: box, viewSize: viewSize, span: span)
    }

    /// The subject box: the authored one, else a small box around the focal anchor.
    nonisolated var subject: BackdropSubjectBox { subjectBox ?? BackdropSubjectBox(around: focalAnchor) }

    /// The subject as fractions of `panel` (clamped to it).
    private nonisolated func subject(in panel: BackdropSubjectBox) -> BackdropSubjectBox {
        let box = subject, width = max(panel.maxX - panel.minX, 0.01), height = max(panel.maxY - panel.minY, 0.01)
        return BackdropSubjectBox(minX: (box.minX - panel.minX) / width, minY: (box.minY - panel.minY) / height,
                                  maxX: (box.maxX - panel.minX) / width, maxY: (box.maxY - panel.minY) / height)
    }

    /// The painting at `scale` with its top-left corner at `origin` (top-left view coordinates),
    /// which covers the view. Whether the subject is kept is measured on the result, never
    /// assumed: its box must lie in the visible span across and in the window top to bottom.
    private nonisolated func place(scale: Double, origin: (x: Double, y: Double), painting: (width: Double, height: Double),
                                   panel: BackdropSubjectBox, box: BackdropSubjectBox, viewSize: CGSize,
                                   span: ClosedRange<Double>) -> BackdropArtPlacement {
        let (vw, vh) = (Double(viewSize.width), Double(viewSize.height))
        let (width, height) = (painting.width * scale, painting.height * scale)
        let slack = 0.5
        let keeps = origin.x + box.minX * width >= span.lowerBound - slack
            && origin.x + box.maxX * width <= span.upperBound + slack
            && origin.y + box.minY * height >= -slack
            && origin.y + box.maxY * height <= vh + slack
        // The view's part of the painting, then of the whole image; flipped, since contentsRect
        // counts from the bottom.
        // Snapped, so a window of the painting's own shape shows exactly all of it.
        let snap = { (value: Double) in abs(value - value.rounded()) < 1e-9 ? value.rounded() : value }
        let fx = snap(min(vw / width, 1)), fy = snap(min(vh / height, 1))
        let left = snap(min(max(-origin.x / width, 0), 1 - fx)), top = snap(min(max(-origin.y / height, 0), 1 - fy))
        let (panelWidth, panelHeight) = (panel.maxX - panel.minX, panel.maxY - panel.minY)
        let contents = CGRect(x: panel.minX + left * panelWidth, y: 1 - (panel.minY + (top + fy) * panelHeight),
                              width: fx * panelWidth, height: fy * panelHeight)
        return .init(contentsRect: contents, frame: CGRect(origin: .zero, size: viewSize), keepsSubject: keeps)
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

    /// The origin at which the image covers the view with the point `fraction` of the way along
    /// the subject as near the middle of the span as the edges allow.
    func nearest(_ scale: Double, at fraction: Double) -> Double {
        let point = subject.lowerBound + (subject.upperBound - subject.lowerBound) * fraction
        let wanted = (span.lowerBound + span.upperBound) / 2 - point * image * scale
        return min(max(wanted, view - image * scale), 0)
    }
}
