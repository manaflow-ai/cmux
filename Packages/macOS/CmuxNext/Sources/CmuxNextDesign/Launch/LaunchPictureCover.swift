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
/// The parts follow their areas at each ``layout()``; a change of the host's size or a live resize (a full-screen
/// toggle resizes too) drops the picture at once, since it would show the window stretched.
///
/// With ``Clicks`` (p08-startup-061) a click on a part still over the host is held (``LaunchPictureClicks``) and
/// raises the part's regions; when the part leaves at its regions' first content the click goes again at the same
/// window point, now to the live view under it, unless what the window shows changed meanwhile or it waited more
/// than ``clickLimit``. A part that leaves at the bound or for its geometry drops its clicks. Without it the parts
/// take no click (the views under them do). Chrome's startup paint preview does the same: a tap on the capture
/// waits for the live tab, which gets it once it painted (`PlayerCompositorDelegateImpl`,
/// chrome/android/java/src/org/chromium/chrome/browser/paint_preview/TabbedPaintPreview.java).
///
/// ```swift
/// cover = LaunchPictureCover(image: picture, over: root, parts: [
///     .init(until: [.sidebar], view: sidebar),
///     .init(until: [.tabs, .pane], view: contentHost),
/// ], reveal: reveal, deadlines: deadlines, clicks: .init(stamp: { shownModel() }, raise: { buildSlices($0) }),
/// onFinish: { keys.end(window: id) })
/// ```
@MainActor
public final class LaunchPictureCover {
    /// How long the picture may stay: then every part leaves, whatever has drawn.
    public static let bound: Duration = .seconds(2)
    /// How long a click on the picture waits for its part to go live.
    public static let clickLimit: Duration = .seconds(2)

    /// What a click on a part still over the host does (p08-startup-061).
    public struct Clicks {
        /// What the window shows now (its workspace or page): a held click whose stamp changed is dropped.
        public var stamp: @MainActor () -> String?
        /// Builds the views of `regions` in the next frame: a click waits for them.
        public var raise: @MainActor (_ regions: Set<LaunchRegion>) -> Void
        /// Sends a held mouse event again through the app, behind the events already queued.
        public var resend: @MainActor (_ event: NSEvent) -> Void
        /// The clock's reading (tests pass their own).
        public var now: @MainActor () -> ContinuousClock.Instant

        public init(stamp: @escaping @MainActor () -> String?, raise: @escaping @MainActor (_ regions: Set<LaunchRegion>) -> Void,
                    resend: @escaping @MainActor (_ event: NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) },
                    now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) {
            (self.stamp, self.raise, self.resend, self.now) = (stamp, raise, resend, now)
        }
    }

    /// The held clicks, shared with the parts' views: a mouse-up still reaches its sent mouse-down's view after
    /// the cover is gone.
    @MainActor private final class ClickHold {
        var clicks = LaunchPictureClicks(limit: LaunchPictureCover.clickLimit)
        let host: Clicks

        init(_ host: Clicks) { self.host = host }

        func release(_ up: NSEvent) {
            for event in clicks.release(up) { host.resend(event) }
        }

        func partDidGoLive(_ part: String) {
            for event in clicks.partDidGoLive(part, stamp: host.stamp(), at: host.now()) { host.resend(event) }
        }
    }

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
        /// The part's name in the held clicks.
        let id: String
        let regions: Set<LaunchRegion>
        /// Nil for the rest of the host: outside every part's area.
        let area: (@MainActor () -> CGRect)?
        let view: PictureView

        init(id: String, regions: Set<LaunchRegion>, area: (@MainActor () -> CGRect)?, image: CGImage) {
            (self.id, self.regions, self.area) = (id, regions, area)
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
    private let hold: ClickHold?
    private let onFinish: @MainActor () -> Void

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
    ///   - clicks: What a click on the picture does; nil, the parts take no click.
    ///   - onFinish: Runs once, in the turn the last part left (its regions drew, the bound, a resize); in this init
    ///     when every region drew before the cover.
    public init(image: CGImage, over host: NSView, parts: [Part], reveal: LaunchReveal, deadlines: MainDeadlineScheduler,
                bound: Duration = LaunchPictureCover.bound, clicks: Clicks? = nil, onFinish: @escaping @MainActor () -> Void = {}) {
        self.host = host
        self.reveal = reveal
        self.onFinish = onFinish
        hold = clicks.map { ClickHold($0) }
        size = host.bounds.size
        partAreas = parts.map(\.area)
        boundDeadline = MainDeadline(owner: "LaunchPicture.bound", workClass: .visible, scheduler: deadlines)
        pieces = [Piece(id: "rest", regions: Set(LaunchRegion.allCases), area: nil, image: image)]
            + parts.enumerated().map { Piece(id: "part-\($0.offset)", regions: $0.element.regions, area: $0.element.area, image: image) }
        for piece in pieces {
            piece.view.frame = host.bounds
            piece.view.autoresizingMask = [.width, .height]
            host.addSubview(piece.view, positioned: .above, relativeTo: nil)
            reveal.coverBegan(piece.regions)
            wireInput(piece)
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
        pieces.contains { covers(point, by: $0) }
    }

    /// Clicks still waiting for their part (``Clicks``).
    public var heldClicks: Int { hold?.clicks.count ?? 0 }

    private func covers(_ point: CGPoint, by piece: Piece) -> Bool {
        guard let host, pieces.contains(where: { $0 === piece }) else { return false }
        if let area = piece.area { return area().contains(point) }
        return host.bounds.contains(point) && !partAreas.contains { $0().contains(point) }
    }

    /// The picture leaves at once, with no fade, and every region shows; its held clicks are dropped.
    public func drop() {
        guard !pieces.isEmpty else { return }
        reveal.showAll()
        for piece in pieces { leave(piece, fades: false, resendsClicks: false) }
    }

    /// The bound: every part leaves and every region shows. A held click is dropped: its region has no content.
    private func finish() {
        reveal.showAll()
        for piece in pieces { leave(piece, fades: true, resendsClicks: false) }
    }

    private func leaveIfDrawn(_ piece: Piece) {
        guard pieces.contains(where: { $0 === piece }), piece.regions.allSatisfy(reveal.isProduced) else { return }
        leave(piece, fades: true, resendsClicks: true)
    }

    private func leave(_ piece: Piece, fades: Bool, resendsClicks: Bool) {
        pieces.removeAll { $0 === piece }
        reveal.coverEnded(piece.regions)
        if let hold {
            if resendsClicks { hold.partDidGoLive(piece.id) } else { hold.clicks.drop(piece.id) }
        }
        if pieces.isEmpty {
            boundDeadline.cancel()
            onFinish()
        }
        let view = piece.view
        // A part the window never drew (its content landed in the cover's own turn) goes with no fade.
        guard fades, view.layer?.presentation() != nil else { return view.removeFromSuperview() }
        Motion.panes.animate(.fadeOut, in: view, { view.animator().alphaValue = 0 }, completion: { view.removeFromSuperview() })
    }

    // MARK: Input (p08-startup-061)

    /// `piece`'s view takes the clicks on its area while it is over the host (with ``Clicks``), and a live resize
    /// drops the picture.
    private func wireInput(_ piece: Piece) {
        let view = piece.view
        view.liveResizeBegan = { [weak self] in self?.drop() }
        guard let hold else { return }
        view.takesClick = { [weak self, weak piece] point in
            guard let self, let piece else { return false }
            return covers(point, by: piece)
        }
        view.pressed = { [weak self, weak piece] event in
            guard let self, let piece, pieces.contains(where: { $0 === piece }) else { return }
            hold.clicks.press(event, part: piece.id, stamp: hold.host.stamp(), at: hold.host.now())
            hold.host.raise(piece.regions)
        }
        view.released = { [hold] event in hold.release(event) }
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

    /// Whether a click at a point of the superview waits on this part (``LaunchPictureCover/Clicks``); nil, never.
    var takesClick: (@MainActor (CGPoint) -> Bool)?
    var pressed: (@MainActor (NSEvent) -> Void)?
    var released: (@MainActor (NSEvent) -> Void)?
    var liveResizeBegan: (@MainActor () -> Void)?

    /// Clicks and scrolls reach the live views under the picture, but on a part that holds them.
    override func hitTest(_ point: NSPoint) -> NSView? { takesClick?(point) == true ? self : nil }
    /// The launch's first click often activates the app too: it is held like any other.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { takesClick != nil }

    override func mouseDown(with event: NSEvent) { pressed?(event) }
    override func rightMouseDown(with event: NSEvent) { pressed?(event) }
    override func otherMouseDown(with event: NSEvent) { pressed?(event) }
    override func mouseUp(with event: NSEvent) { released?(event) }
    override func rightMouseUp(with event: NSEvent) { released?(event) }
    override func otherMouseUp(with event: NSEvent) { released?(event) }
    // A drag or a scroll on a part that holds clicks means nothing: no view under it is built to take it.
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDragged(with event: NSEvent) {}
    override func otherMouseDragged(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeBegan?()
    }

    override func isAccessibilityElement() -> Bool { false }
}
