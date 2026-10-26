public import AppKit
public import CmuxNextDesignTokens
public import CmuxNextWakeups

/// The window's saved picture over its live root while the launch builds the root under it (p08-startup-060), in
/// parts. Each part covers one area of the host (the sidebar, the main pane) and fades out (`Motion.panes`,
/// `.fadeOut`; one frame with animations off) once each of its regions has its first content
/// (``LaunchReveal/whenProduced(_:_:)``: the sidebar's first rows, the first tab strip, the first terminal frame or
/// page paint), so the window goes live region by region. The rest of the host (the title row, the gutters) leaves
/// with the last part. ``bound`` after the cover every part leaves and every region shows, data or not: a region
/// shows either its part of the picture or its live views, never the glass alone. The views under a part show at
/// once (``LaunchReveal`` does not fade a covered region), so the part's fade is the only one.
///
/// Chrome's Android startup does this for its first tab (`StartupPaintPreview`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/StartupPaintPreview.java): the capture shows
/// until the tab's first meaningful paint, then fades out.
///
/// The parts take no click (the views under them do) and follow their areas at each ``layout()``; a change of the
/// host's size drops the picture at once, since it would show the window stretched.
///
/// ```swift
/// cover = LaunchPictureCover(image: picture, over: root, parts: [
///     .init(until: [.sidebar], view: sidebar),
///     .init(until: [.tabs, .pane], view: contentHost),
/// ], reveal: reveal, deadlines: deadlines)
/// ```
@MainActor
public final class LaunchPictureCover {
    /// How long the picture may stay: then every part leaves, whatever has drawn.
    public static let bound: Duration = .seconds(2)

    /// One area of the host the picture covers and the regions whose first content lets it go.
    public struct Part {
        let regions: Set<LaunchRegion>
        let area: @MainActor () -> CGRect

        /// - Parameters:
        ///   - regions: The regions that draw in the area; the part leaves once each has its first content.
        ///   - area: The area in the host's coordinates, asked again at each ``LaunchPictureCover/layout()``.
        public init(until regions: Set<LaunchRegion>, area: @escaping @MainActor () -> CGRect) {
            (self.regions, self.area) = (regions, area)
        }

        /// A part over `view`, a subview of the host: its frame, none while it is hidden.
        public init(until regions: Set<LaunchRegion>, view: NSView) {
            self.init(until: regions) { [weak view] in view.map { $0.isHidden ? .zero : $0.frame } ?? .zero }
        }
    }

    @MainActor private final class Piece {
        let regions: Set<LaunchRegion>
        /// Nil for the rest of the host: outside every part's area.
        let area: (@MainActor () -> CGRect)?
        let view: PictureView

        init(regions: Set<LaunchRegion>, area: (@MainActor () -> CGRect)?, image: CGImage) {
            (self.regions, self.area) = (regions, area)
            view = PictureView(image: image)
        }
    }

    private weak var host: NSView?
    private let reveal: LaunchReveal
    /// The parts still over the host; a leaving part is out of the list while it fades.
    private var pieces: [Piece] = []
    private let partAreas: [@MainActor () -> CGRect]
    private let size: CGSize
    private let boundDeadline: MainDeadline

    /// Whether every part left.
    public var isFinished: Bool { pieces.isEmpty }

    /// Covers `host` with `image`, drawn over its whole bounds, at once (in this turn's frame).
    ///
    /// - Parameters:
    ///   - image: The host's picture from the last quit, at the host's size.
    ///   - host: The window's root view; the parts go on top of its subviews.
    ///   - parts: The areas that leave on their own; the rest leaves with the last of them.
    ///   - reveal: The launch's regions.
    ///   - deadlines: The app's main-thread deadlines, which time the bound (a visible-class deadline).
    ///   - bound: How long the picture may stay.
    public init(image: CGImage, over host: NSView, parts: [Part], reveal: LaunchReveal, deadlines: MainDeadlineScheduler,
                bound: Duration = LaunchPictureCover.bound) {
        self.host = host
        self.reveal = reveal
        size = host.bounds.size
        partAreas = parts.map(\.area)
        boundDeadline = MainDeadline(owner: "LaunchPicture.bound", workClass: .visible, scheduler: deadlines)
        pieces = [Piece(regions: Set(LaunchRegion.allCases), area: nil, image: image)]
            + parts.map { Piece(regions: $0.regions, area: $0.area, image: image) }
        for piece in pieces {
            piece.view.frame = host.bounds
            piece.view.autoresizingMask = [.width, .height]
            host.addSubview(piece.view, positioned: .above, relativeTo: nil)
            reveal.coverBegan(piece.regions)
        }
        layout()
        for piece in pieces {
            for region in piece.regions {
                reveal.whenProduced(region) { [weak self, weak piece] in
                    if let piece { self?.leaveIfDrawn(piece) }
                }
            }
        }
        guard !pieces.isEmpty else { return }
        boundDeadline.schedule(after: bound) { [weak self] in self?.finish() }
    }

    /// Keeps each part on its area; the host calls it from its `layout()`. A change of the host's size drops the
    /// picture.
    ///
    /// - Returns: False once every part left (the host may let the cover go).
    @discardableResult
    public func layout() -> Bool {
        guard let host, !pieces.isEmpty else { return false }
        guard host.bounds.size == size else {
            drop()
            return false
        }
        for piece in pieces {
            let view = piece.view
            if let area = piece.area {
                view.setArea(CGPath(rect: view.convert(area(), from: host), transform: nil), evenOdd: false)
            } else {
                let path = CGMutablePath()
                path.addRect(view.bounds)
                for area in partAreas { path.addRect(view.convert(area(), from: host)) }
                view.setArea(path, evenOdd: true)
            }
        }
        return true
    }

    /// Whether a part still over the host covers `point`, in the host's coordinates.
    public func covers(_ point: CGPoint) -> Bool {
        guard let host else { return false }
        return pieces.contains { piece in
            if let area = piece.area { return area().contains(point) }
            return host.bounds.contains(point) && !partAreas.contains { $0().contains(point) }
        }
    }

    /// The picture leaves at once, with no fade, and every region shows.
    public func drop() {
        reveal.showAll()
        for piece in pieces { leave(piece, fades: false) }
    }

    /// The bound: every part leaves and every region shows.
    private func finish() {
        reveal.showAll()
        for piece in pieces { leave(piece, fades: true) }
    }

    private func leaveIfDrawn(_ piece: Piece) {
        guard pieces.contains(where: { $0 === piece }), piece.regions.allSatisfy(reveal.isProduced) else { return }
        leave(piece, fades: true)
    }

    private func leave(_ piece: Piece, fades: Bool) {
        pieces.removeAll { $0 === piece }
        reveal.coverEnded(piece.regions)
        if pieces.isEmpty { boundDeadline.cancel() }
        let view = piece.view
        // A part the window never drew (its content landed in the cover's own turn) goes with no fade.
        guard fades, view.layer?.presentation() != nil else { return view.removeFromSuperview() }
        Motion.panes.animate(.fadeOut, in: view, { view.animator().alphaValue = 0 }, completion: { view.removeFromSuperview() })
    }
}

/// One part of the picture: the whole image over the host, masked to the part's area.
private final class PictureView: NSView {
    private let mask = CAShapeLayer()

    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        // The picture and its area change in one frame: no implicit move or fade, animations on or off.
        layer?.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.contents = image
        layer?.contentsGravity = .resize
        mask.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.mask = mask
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setArea(_ path: CGPath, evenOdd: Bool) {
        mask.frame = bounds
        mask.fillRule = evenOdd ? .evenOdd : .nonZero
        mask.path = path
    }

    /// Clicks and scrolls reach the live views under the picture.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func isAccessibilityElement() -> Bool { false }
}
