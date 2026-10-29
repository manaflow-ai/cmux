import AppKit
import CmuxNextDesign
import QuartzCore
#if DEBUG
import os
#endif

/// Wraps one App-provided pane view. The content sits in `clipView`, the
/// cell inset by the pane padding. A view that reports a header
/// (`PaneContentChrome`: the tab strip) rounds its own content area, one
/// container for terminal, browser toolbar and page alike, and the chrome
/// traces that area only; any other view is
/// clipped to a rounded rect here, header and all. Layer clips take the
/// Ghostty Metal layer and WebKit along; Chromium pages are child windows
/// no clip reaches, so the browser module reads the rounded ancestor and
/// masks the page itself.
///
/// The focus ring, border and inactive dim (`chrome`) live in the layout's
/// `OverlayPlane`, not in this view, so they draw above content that is a
/// child window (Chromium pages); the root keeps them on this view's
/// displayed frame.
final class PaneHostView: NSView, RestingPlacement {
    let pane: PaneID
    let content: NSView
    let chrome = PaneOverlayView()
    private let clipView = PaneClipView()
    private(set) var padding: CGFloat = 0
    private(set) var cornerRadius: CGFloat = 0
    /// Floating panes: the whole padded rect, header included, is the
    /// rounded card the clip, border and ring trace (`LayoutStyle.floatingPanes`).
    private(set) var wholeCard = false
    private var reporter: PaneContentChrome? { content as? PaneContentChrome }
    private var lastWindowFrame: CGRect?
    /// The window frame changed since the content last heard its place settle (``settlePlacement()``).
    private var placementUnsettled = false

    /// Render-server spring calls on the host's layer that have not landed yet (`PaneHostView+RenderSpring.swift`).
    var renderSpringsInFlight = 0

    /// `RestingPlacement`: Core Animation shows the host moving or resizing away from its frame, which is at rest
    /// (`PaneHostView+RenderSpring.swift`). With page resizing (`pageResizing`, the `pageSpringResizeOnce`
    /// feature) its changes reach the content's `PaneRenderMoveObserving` views, so a page in its own window
    /// hides for the move; without it they reach nothing.
    var showsRenderMove = false {
        didSet {
            guard showsRenderMove != oldValue, pageResizing != nil else { return }
            content.notifyPaneRenderMoveChanged(showsRenderMove)
        }
    }

    /// What pages in the content do while the host springs (`RestingPlacement`); nil: they resize with it.
    let pageResizing: PageSpringResizing?

    init(pane: PaneID, content: NSView, pageResizing: PageSpringResizing? = nil) {
        self.pane = pane
        self.content = content
        self.pageResizing = pageResizing
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        clipView.frame = bounds
        // `layoutClip` places the content itself, at the clip's bounds, once per frame size.
        clipView.autoresizesSubviews = false
        addSubview(clipView)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = clipView.bounds
        clipView.addSubview(content)
        // A header change comes from inside the content's layout pass: it
        // reshapes the rounded area and the ring only, and moves no frame of
        // this view or of the content (an ancestor of the reporter).
        reporter?.onPaneHeaderHeightChange = { [weak self] in self?.applyChromeShape() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    /// Where the host will rest minus where it shows now (`RestingPlacement`): its spring rect's
    /// target and the strip camera's target, against the presented frame. Zero at rest; coming
    /// to rest tells the content, whose window-relative chrome held its motion layout.
    var restOffset: CGVector = .zero {
        didSet { if restOffset == .zero, oldValue != .zero, window != nil { reporter?.paneFrameInWindowDidChange() } }
    }

    /// Whether the host's frame is on a layout spring (`RestingPlacement`): set before the frame of
    /// each moving display frame and cleared after the frame it lands at, so content resized on the
    /// landing frame still sees the motion, then hears it end once (`PaneMotionSettling`): a
    /// terminal reports its grid there, one PTY resize per zoom instead of one per frame.
    var isOnLayoutSpring = false {
        didSet {
            guard oldValue != isOnLayoutSpring else { return }
            guard !isOnLayoutSpring else { return }
            // The one layout at the size the spring landed at, before the content hears it landed.
            layoutClip()
            content.notifyPaneMotionSettled()
            #if DEBUG
            checkRestingContent()
            #endif
        }
    }

    /// The host's size at rest (its spring rect's target), set with ``restOffset`` on every
    /// presented frame; nil before the screen first places it.
    var restSize: CGSize?

    /// A host taken out of the layout mid-spring is at rest: its content reports what it holds.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            // Its render-server springs end now; their landings still run (``springToRest(_:spring:inPlane:landed:)``).
            if let layer, isOnRenderSpring { for keyPath in Self.renderSpringKeyPaths { RenderSpring.stop(layer, keyPath) } }
            showsRenderMove = false
            isOnLayoutSpring = false
        }
        // Another screen (or none) places it now: its clip, overlay and covers are computed afresh.
        stripClipInput = nil
        overlaySyncKey = nil
        pageCoverMemo = nil
    }

    /// The panes in front last read for a page in this host (`pageCovers`), with the screen's
    /// `coverVersion` they were read at.
    private var pageCoverMemo: (screen: ObjectIdentifier, version: Int, covers: [CGRect])?

    /// What the host's strip clip was last computed from (`ScreenContentView.clipToStrip`).
    var stripClipInput: StripClipInput?
    /// What its ring and dim were last placed from (`LayoutRootView.syncOverlay`).
    var overlaySyncKey: PaneOverlaySyncKey?
    /// The chrome state last applied (`setChrome`); nil before the first.
    private var chromeInputs: PaneChromeInputs?

    /// Whether the pane sits in a docked column: it then shows the
    /// user's docks background under its content (`appearance.surfaces.docks`).
    var isDocked = false {
        didSet { if isDocked != oldValue { applyDockFill() } }
    }

    override func viewDidChangeEffectiveAppearance() { // visibility-walk-allow: one layer background color (the dock fill), no layout or text measure; cheaper than a deferral
        super.viewDidChangeEffectiveAppearance()
        applyDockFill()
    }

    private func applyDockFill() {
        clipView.layer?.backgroundColor = isDocked ? performWithTheme { Palette.surfaceOverride(.docks)?.cgColor } : nil
    }

    /// Height of the content's header (tab strip, toolbar); 0 without one.
    var headerHeight: CGFloat { reporter?.paneHeaderHeight ?? 0 }
    /// Height of the content's footer (a tab strip at the bottom); 0 without one.
    var footerHeight: CGFloat { reporter?.paneFooterHeight ?? 0 }
    /// The header and footer the rounding leaves out: none for a whole card.
    private var roundedBands: (header: CGFloat, footer: CGFloat) { wholeCard ? (0, 0) : (headerHeight, footerHeight) }

    /// The padded rect the content view fills, in this view's coordinates.
    var contentRect: CGRect { clipView.frame }

    /// The card a floating pane shows, in window coordinates: the padded
    /// rect cut to the part the strip shows (`stripShownRect`).
    var cardInWindow: CGRect {
        let visible = contentRect.intersection(stripShownRect)
        return convert(visible.isNull ? .zero : visible, to: nil)
    }

    /// The part of this host the layout shows (own coordinates): its bounds cut by its own mask (a
    /// scroll area's window or a held strip range, `setStripClip`) and by the clipping pan containers it
    /// sits in (the strip container, a scroll area's, `PanMotionContainer`); `.zero` when none of it shows.
    var stripShownRect: CGRect {
        var shown = bounds
        if let mask = layer?.mask { shown = shown.intersection(mask.frame) }
        // A container's clip stays where it is while the pans at or below it move this host by their translations.
        var moved = CGVector.zero
        var current = superview
        while let container = current as? any PanMotionContainer {
            moved.dx += container.panTranslation.dx
            moved.dy += container.panTranslation.dy
            if container.clipsSubviews {
                shown = shown.intersection(convert(container.bounds.offsetBy(dx: -moved.dx, dy: -moved.dy), from: container))
            }
            current = container.superview
        }
        return shown.isNull ? .zero : shown
    }

    /// The rounded area the border and ring trace: between the content's
    /// header and footer, or the whole padded rect for content without them.
    var roundedRect: CGRect {
        PaneChromeGeometry.roundedRect(inPadded: clipView.frame, headerHeight: roundedBands.header, footerHeight: roundedBands.footer)
    }

    /// Applies the pane padding and corner radius (live style values).
    func applyShape(padding: CGFloat, cornerRadius: CGFloat, wholeCard: Bool = false) {
        guard padding != self.padding || cornerRadius != self.cornerRadius || wholeCard != self.wholeCard else { return }
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.wholeCard = wholeCard
        layoutClip()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        // `frame =` with only a new origin calls this too: the clip and content keep their size.
        if changed { layoutClip() }
    }

    /// Clip and content layouts this host ran, cumulative (PaneMotionWorkTests: a pane that only
    /// moves lays out nothing).
    private(set) var clipLayouts = 0

    private func layoutClip() {
        clipLayouts += 1
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let rect = PaneChromeGeometry.contentRect(forCell: bounds, style: style)
        if clipView.frame != rect { clipView.frame = rect }
        // A restored pane can be populated before its host receives the
        // launch frame. AppKit does not reliably run the child's autoresizing
        // pass when the clip view is resized manually, so keep the content
        // frame in lockstep with the clip bounds here.
        // The content always takes the clip's bounds: the final-size path of each content kind is inside it (a
        // terminal's surface hold, a page's spring hold; `PaneMotionHolding`), never a second hold here.
        if content.frame != clipView.bounds { content.frame = clipView.bounds }
        applyChromeShape()
    }

    /// The content's rounded corners and the ring's shape from the current
    /// clip frame and the content's header and footer. Changes no frame.
    private func applyChromeShape() {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let rect = clipView.frame
        let (header, footer) = roundedBands
        let rounded = PaneChromeGeometry.roundedRect(inPadded: rect, headerHeight: header, footerHeight: footer)
        let radius = PaneChromeGeometry.cornerRadius(for: rounded, style: style)
        if let reporter, !wholeCard {
            clipView.setCornerRadius(0)
            reporter.setPaneContentCornerRadius(radius)
        } else {
            reporter?.setPaneContentCornerRadius(0)
            clipView.setCornerRadius(radius)
        }
        chrome.setShape(padding: padding, cornerRadius: cornerRadius, headerHeight: header, footerHeight: footer)
    }

    /// Tells the content (every ``PaneMotionTargeting`` view in it) how much larger its area will rest than
    /// it is now (`restSize` against the current frame, both less the padding): called by the screen once
    /// when a spring starts or retargets to a new size, never per frame.
    func announceRest() {
        guard let change = restSizeChange else { return }
        content.notifyPaneMotionWillRest(sizeChange: change)
        #if DEBUG
        checkSpringingContent()
        #endif
    }

    /// The content area at rest (``restSize`` less the padding) minus the content's size now; nil without a
    /// rest size or with no change.
    private var restSizeChange: CGSize? {
        guard let restSize else { return nil }
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let rest = PaneChromeGeometry.contentRect(forCell: CGRect(origin: .zero, size: restSize), style: style).size
        let now = content.frame.size
        let change = CGSize(width: rest.width - now.width, height: rest.height - now.height)
        guard abs(change.width) >= 0.5 || abs(change.height) >= 0.5 else { return nil }
        return change
    }

    #if DEBUG
    /// What ``checkRestingContent()`` and ``checkSpringingContent()`` found against R3 (principled audit, row
    /// paneHoldsContentInMotion; felt 1d), newest last; each is also a fault in the log. Tests read it.
    private(set) var motionHoldViolations: [String] = []

    private func noteMotionHoldViolation(_ message: String) {
        motionHoldViolations.append(message)
        if motionHoldViolations.count > 32 { motionHoldViolations.removeFirst() }
        Self.motionLog.fault("pane \(self.pane.rawValue, privacy: .public): \(message, privacy: .public)")
    }

    private static let motionLog = Logger(subsystem: "com.cmuxterm.app", category: "pane-motion-holds")

    /// R3, at each landing: a host that is not springing has its content at the clip's bounds and no hold anywhere
    /// in its subtree (no surface hold, no spring hold; the host itself holds nothing), so the end state is the one a
    /// pane that never moved has.
    func checkRestingContent() {
        guard !isOnLayoutSpring, !isOnRenderSpring else { return }
        if content.frame != clipView.bounds { noteMotionHoldViolation("at rest, content \(content.frame) is not the clip \(clipView.bounds)") }
        let holds = content.paneMotionHolds()
        if !holds.isEmpty { noteMotionHoldViolation("at rest, \(holds.count) hold(s) remain: \(holds.map { String(describing: type(of: $0.view)) })") }
    }

    /// R3, at each spring start or retarget: at most one hold sizes any one content view (no holding view inside
    /// another one that holds).
    func checkSpringingContent() {
        let nested = content.paneMotionHolds().filter { $0.enclosingHolds > 0 }
        if !nested.isEmpty { noteMotionHoldViolation("springing, a hold inside another hold: \(nested.map { String(describing: type(of: $0.view)) })") }
    }
    #endif

    /// `RestingPlacement`: the size change a view joining the content mid-spring will rest at.
    var restContentSizeChange: CGSize? { isOnLayoutSpring ? restSizeChange : nil }

    /// Tells the content when the pane's frame in the window changed, and, out of layout motion (`inMotion`
    /// false) and the window's content-area motion, that its place is final (``settlePlacement()``). A content-area
    /// motion's landing tells it (`NSView.notifyPaneMotionSettled`).
    func noteWindowFrame(inMotion: Bool) {
        guard window != nil else { return }
        let frame = convert(bounds, to: nil)
        if frame != lastWindowFrame {
            lastWindowFrame = frame
            placementUnsettled = true
            reporter?.paneFrameInWindowDidChange()
        }
        if !inMotion, !isInPaneMotion { settlePlacement() }
    }

    /// Tells the content (`PanePlacementFollowing`) once that the host's place in the window is final, when it
    /// moved since the content last heard: the layout calls it when its motion ends (`LayoutRootView.setLayoutInMotion`).
    func settlePlacement() {
        guard placementUnsettled, window != nil else { return }
        placementUnsettled = false
        content.notifyPanePlacementSettled()
    }

    /// `RestingPlacement`: the render server shows this host's spring, its frame set at rest at the start.
    var framePlacedAtRest: Bool { isOnRenderSpring || !isOnLayoutSpring }

    /// The part of this host (own coordinates) that takes clicks while it sits in a scroll area
    /// (scroll-areas-DESIGN.md): what scrolled out of the area's window is masked away and must
    /// not take clicks meant for the view beside the area. Nil outside an area.
    var areaHitClip: CGRect?

    /// Presentation-layer reads of its hit tests (`PaneHostView+RenderSpring.swift`), cumulative: none at rest.
    var presentedHitReads = 0

    /// Clips the host to `rect` (its own coordinates): the part of it inside its scroll area's
    /// window, and the strip's range it keeps while a zoom lifts the strip container; nil removes the
    /// clip. The strip's clip beside docked columns is otherwise not a mask: the strip container
    /// clips its hosts (`StripClipContainerView`), and panes in front are above this one in the
    /// layer tree.
    /// `cover` (its own coordinates): the part a zooming or unzooming pane in front of it shows over now
    /// (`ScreenContentView.zoomCover`), cut out of the clip, so nothing of this pane shows through that
    /// pane, which has a resting pane's material (no fill of its own; felt 1d, Lawrence 2026-10-29: an opaque
    /// fill under the zooming pane read as a dark layer wiping in). The cut is a hole in a shape mask whose
    /// frame is still the clip's rect.
    /// Returns true when the clip changed: a Chromium page in this pane then
    /// re-reads its clip shape, which carries this mask (`CEFClipShape`).
    @discardableResult
    func setStripClip(_ rect: CGRect?, cover: CGRect? = nil) -> Bool {
        guard let layer else { return false }
        let outer = rect ?? bounds
        if let cover = cover?.intersection(outer), !cover.isNull, cover.width > 0.5, cover.height > 0.5 {
            return setCoverMask(outer: outer, cover: cover, on: layer)
        }
        guard let rect else {
            guard layer.mask != nil else { return false }
            layer.mask = nil
            return true
        }
        let mask = (layer.mask as? StripClipMaskLayer) ?? {
            // A zoom's cover mask (``ZoomCoverMaskLayer``) gives way to the plain clip once the zoom no longer covers it.
            let mask = StripClipMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            layer.mask = mask
            return mask
        }()
        guard mask.frame != rect || mask.backgroundColor == nil else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.place(rect)
        CATransaction.commit()
        return true
    }

    /// The clip `outer` less `cover` (both this host's coordinates, `cover` inside `outer`): a shape mask whose
    /// bounds are `outer`, so its frame is the clip's rect as for ``StripClipMaskLayer`` (``stripShownRect``,
    /// `CEFClipShape` read that frame), with the hole subtracted from its path. The bounds and path are in this
    /// view's coordinates, as `PaneOverlayView`'s exclusion mask places them. One path per frame of a zoom, on
    /// the panes under the zooming one only.
    private func setCoverMask(outer: CGRect, cover: CGRect, on layer: CALayer) -> Bool {
        let mask = (layer.mask as? ZoomCoverMaskLayer) ?? {
            let mask = ZoomCoverMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            mask.fillRule = .nonZero
            return mask
        }()
        guard mask.bounds != outer || mask.cover != cover || layer.mask !== mask else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.bounds = outer
        mask.position = CGPoint(x: outer.midX, y: outer.midY)
        mask.cover = cover
        mask.path = CGPath(rect: outer, transform: nil).subtracting(CGPath(rect: cover, transform: nil))
        CATransaction.commit()
        if layer.mask !== mask { layer.mask = mask }
        return true
    }

    func setChrome(showsRing: Bool, dim: CGFloat, dimFill: PaneOverlayView.DimFill = .pane, focusRing: FocusRingSettings,
                   ringAlphaOverride: CGFloat? = nil, tabEmphasis: ChromeEmphasis = .full, border: PaneOverlayView.Border,
                   attention: AttentionMark?, attentionSettings: AttentionSettings, readByEntry: Bool = false,
                   focused: Bool = false, flashesFocus: Bool = false, animated: Bool) {
        // A split or close re-runs every pane's chrome; a pane whose ring, dim, border, emphasis and
        // attention are what they were keeps them as they are (no layer transactions per pane). A
        // focus flash always runs: it is an event, not a state.
        let inputs = PaneChromeInputs(showsRing: showsRing, dim: dim, dimFill: dimFill, focusRing: focusRing,
                                      ringAlphaOverride: ringAlphaOverride, tabEmphasis: tabEmphasis, border: border,
                                      attention: attention, attentionSettings: attentionSettings, readByEntry: readByEntry,
                                      focused: focused)
        guard flashesFocus || inputs != chromeInputs else { return }
        chromeInputs = inputs
        reporter?.setChromeEmphasis(tabEmphasis, animated: animated)
        chrome.update(showsRing: showsRing, dim: dim, dimFill: dimFill, focusRing: focusRing, ringAlphaOverride: ringAlphaOverride, border: border,
                      attention: attention, attentionSettings: attentionSettings, readByEntry: readByEntry,
                      focused: focused, flashesFocus: flashesFocus, animated: animated)
    }
}

/// A Chromium page in this pane that draws in its own window leaves out what the panes in front
/// cover (`ChildWindowPageFallback`): asked at the page's clip read, never on a motion frame. The
/// answer is kept until the screen's `coverVersion` moves on, so a read at rest walks nothing.
extension PaneHostView: PageCoverSource {
    func pageCovers() -> [CGRect] {
        var ancestor = superview
        while let current = ancestor, !(current is ScreenContentView) { ancestor = current.superview }
        guard let screen = ancestor as? ScreenContentView else { return [] }
        if let memo = pageCoverMemo, memo.screen == ObjectIdentifier(screen), memo.version == screen.coverVersion { return memo.covers }
        let covers = screen.panes(inFrontOf: self).map { convert($0, from: screen) }
        pageCoverMemo = (ObjectIdentifier(screen), screen.coverVersion, covers)
        return covers
    }
}

/// A pane's clip with the part a zooming pane in front covers cut out (``PaneHostView/setStripClip(_:cover:)``).
nonisolated final class ZoomCoverMaskLayer: CAShapeLayer {
    /// The hole, in the masked host's coordinates.
    var cover: CGRect = .null

    override init() { super.init() }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? ZoomCoverMaskLayer { cover = other.cover }
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }
}
