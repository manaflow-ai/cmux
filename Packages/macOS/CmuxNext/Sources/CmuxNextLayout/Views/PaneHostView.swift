import AppKit
import CmuxNextDesign
import QuartzCore

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
    private(set) var pane: PaneID
    let content: NSView
    let chrome = PaneOverlayView()
    let clipView = PaneClipView()
    private(set) var padding: CGFloat = 0
    private(set) var cornerRadius: CGFloat = 0
    /// Floating panes: the whole padded rect, header included, is the
    /// rounded card the clip, border and ring trace (`LayoutStyle.floatingPanes`).
    private(set) var wholeCard = false
    private var reporter: PaneContentChrome? { content as? PaneContentChrome }
    /// Whether the content draws its pane's outline and ring (`PaneContentChrome.paneFramesContent`):
    /// an agent chat does not, and the dividers beside it draw their line instead (`ScreenContentView.showsIdleLine`).
    var framesContent: Bool { reporter?.paneFramesContent ?? true }
    private var lastWindowFrame: CGRect?

    init(pane: PaneID, content: NSView) {
        self.pane = pane
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        clipView.frame = bounds
        // `layoutClip` places the content itself: autoresizing would resize a key hold's content on every
        // spring frame before it is set back (`contentFrame(in:)`).
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

    /// A host made ahead (``LayoutViewContext/parkSpare(_:in:)``) becomes `pane`'s when that pane adopts its content.
    func adopt(_ pane: PaneID) { self.pane = pane }

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
            if isOnLayoutSpring {
                // A keyboard resize: content with a hold area (the app's pane content) follows its pane in every frame
                // and only its area's producers hold (a terminal's surface, a Chromium page); content with no such area
                // (the Home with its tools in the tab row, `PaneKeyResizeHeld`) holds whole at its START size and lays
                // out once, after the landing (RESIZE KEYS K3).
                if let screen = superview as? ScreenContentView, screen.holdsContentForKeyResize {
                    // A hold still waiting for its release keeps its size and edge (a press during the last one's tail).
                    if !holdsUntilAfterLanding {
                        holdsUntilAfterLanding = true
                        heldContentSize = content.frame.size
                        heldPin = nil
                        heldArea = (content as? PaneMotionHolding)?.paneMotionHoldArea
                        announcedRest = nil
                        // The area hears the hold in the key's turn, before the press's rest size goes to the content
                        // (`announceRest`): the surface takes its final size at the edge that stays, never at another
                        // edge for one frame. No frame changes here: the host is still at its start size.
                        if heldArea != nil { layoutClip() }
                    }
                    return
                }
                // On any other spring (a split, a close, a zoom) the content of every kind follows its pane in every frame:
                // a key hold waiting for its release ends here.
                (holdsUntilAfterLanding, heldPin, heldContentSize) = (false, nil, nil)
                syncHeldArea()
            } else if holdsUntilAfterLanding, let context = (superview as? ScreenContentView)?.context {
                // The landing frame shows the panes at rest with the content still held; the one layout runs after that
                // frame's commit, when nothing moves. A new spring before then keeps the hold.
                context.afterCommit { [weak self] in
                    guard let self, !self.isOnLayoutSpring, self.holdsUntilAfterLanding else { return }
                    self.releaseHeldContent()
                }
            } else {
                releaseHeldContent()
            }
        }
    }

    /// A structural change (a split, a close, a zoom) took over the screen while its key-resize spring ran: a pane
    /// already on that spring keeps moving without a new start, so it leaves the key hold here and follows the
    /// structural spring in every frame, as every pane on it does.
    func endKeyResizeHold() {
        guard holdsUntilAfterLanding else { return }
        guard isOnLayoutSpring else { return releaseHeldContent() }
        (holdsUntilAfterLanding, heldPin, heldContentSize) = (false, nil, nil)
        layOutLetGoContent() // the structural spring's start measures the content's live size (`announceRest`)
    }

    /// The one layout at the size the spring landed at, before the content hears it landed.
    private func releaseHeldContent() {
        (holdsUntilAfterLanding, heldPin, heldContentSize, heldAnchor, announcedRest) = (false, nil, nil, nil, nil)
        layOutLetGoContent()
        content.notifyPaneMotionSettled()
    }

    /// Let-go content lays out its whole subtree now (a terminal measures from its host: D1), at a real size in a window.
    private func layOutLetGoContent() {
        layoutClip()
        if window != nil, bounds.width >= 1, bounds.height >= 1 { layoutSubtreeIfNeeded() }
    }

    /// A keyboard resize's hold (``ScreenContentView/holdsContentForKeyResize``), until after the landing: content with
    /// a hold area follows its pane (``heldArea``); any other content keeps its start size, clipped where the pane is
    /// smaller and beside the pane background where it is larger.
    private var holdsUntilAfterLanding = false
    /// The edges a key-resize hold rides, chosen while the pane moves and kept until the release: at rest (the landing
    /// frame) the rest offset no longer says which edge moved, and a new pick would jump the content by the press step.
    private var heldPin: (trailing: Bool, bottom: Bool)?
    /// FRAME OWNER S1 (latched per hold): the content takes the pane's rect in every frame of a key-resize hold, its tab
    /// strip with it, and this area tells the producers in it to hold, on ``heldPin``. Nil: the whole content holds
    /// (content with no ``PaneMotionHolding`` area; of the app's pane content only the Home that draws its tools in the
    /// pane's tab row, the stated exception `PaneKeyResizeHeld`).
    /// FRAME OWNER S3: the views in it (a terminal's host, a browser's chrome, a chat, a page) follow the pane too and
    /// only their producers hold, fixed at the pane edges that do not move (``heldPin`` then reads those edges only, not
    /// the content's anchor).
    private weak var heldArea: PaneContentAreaView?

    /// The host's size at rest (its spring rect's target), set with ``restOffset`` on every
    /// presented frame; nil before the screen first places it.
    var restSize: CGSize?

    /// The content's size when a key hold began; nil at rest and on every other spring.
    private var heldContentSize: CGSize?

    /// The content's frame in the clip: the clip's bounds, at rest and in every frame of a split, a close or a zoom, for
    /// every kind of content (Lawrence 2026-11-11: "all must have smooth transition"). Only a key hold of content with no
    /// area to hold (``heldArea``) keeps the whole content at its start size, pinned at the edge that stays.
    private func contentFrame(in clip: CGRect) -> CGRect {
        if holdsUntilAfterLanding, let held = heldContentSize {
            // Pinned at the edge nearer its rest, picked once when the pane first moves and kept to the
            // release: on a 2x screen the last frames are half a point from rest, too close to say which edge moved.
            if heldPin == nil, let restSize, restOffset != .zero || frame.size != restSize {
                let trailing = abs(restOffset.dx + restSize.width - frame.width) < abs(restOffset.dx) - 0.5
                let still = abs(restOffset.dy + restSize.height - frame.height) < abs(restOffset.dy) - 0.5
                let bottom = heldArea != nil ? still : heldAnchor.map { $0 == .bottom } ?? still
                heldPin = (trailing, bottom)
            }
            // Content whose area holds follows the pane: `syncHeldArea` gives that area the edges.
            if heldArea != nil { return clip }
            let pin = heldPin ?? (trailing: false, bottom: false)
            return CGRect(x: pin.trailing ? clip.maxX - held.width : clip.minX, y: pin.bottom == isFlipped ? clip.maxY - held.height : clip.minY,
                          width: held.width, height: held.height)
        }
        return clip
    }

    /// A host taken out of the layout mid-spring is at rest: its content reports what it holds.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil { isOnLayoutSpring = false }
        // Another screen (or none) places it now: its clip and overlay are computed afresh.
        stripClipInput = nil
        overlaySyncKey = nil
    }

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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyDockFill()
    }

    func applyDockFill() {
        guard !showsClosingGround else { return }
        clipView.layer?.backgroundColor = isDocked ? performWithTheme { Palette.surfaceOverride(.docks)?.cgColor } : nil
    }

    /// FRAME OWNER S3c: the host shows only its pane's ground on its close spring (`PaneHostView+ClosingGround`).
    var showsClosingGround = false

    /// Height of the content's header (tab strip, toolbar); 0 without one.
    var headerHeight: CGFloat { reporter?.paneHeaderHeight ?? 0 }
    /// Height of the content's footer (a tab strip at the bottom); 0 without one.
    var footerHeight: CGFloat { reporter?.paneFooterHeight ?? 0 }
    /// The header and footer the rounding leaves out: none for a whole card.
    private var roundedBands: (header: CGFloat, footer: CGFloat) { wholeCard ? (0, 0) : (headerHeight, footerHeight) }

    /// The padded rect the content view fills, in this view's coordinates.
    var contentRect: CGRect { clipView.frame }

    /// The card a floating pane shows, in window coordinates: the padded
    /// rect cut to the part a docked column leaves (`setStripClip`).
    var cardInWindow: CGRect {
        let visible = layer?.mask.map { contentRect.intersection($0.frame) } ?? contentRect
        return convert(visible, to: nil)
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
        // `frame =` with only a new origin calls this too: the clip and content keep their size
        // (a key hold's content is pinned by the rest offset, which a move changes: it lays out).
        if changed || heldContentSize != nil { layoutClip() }
    }

    /// Clip and content layouts this host ran, cumulative (PaneMotionWorkTests: a pane that only
    /// moves lays out nothing).
    private(set) var clipLayouts = 0

    /// The clip's frame in a host whose bounds are `cell`: the cell inset by the pane padding.
    private func clipRect(forCell cell: CGRect) -> CGRect {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        return PaneChromeGeometry.contentRect(forCell: cell, style: style)
    }

    private func layoutClip() { // perf-hot: 4ms motion-frame
        clipLayouts += 1
        let rect = clipRect(forCell: bounds)
        if clipView.frame != rect { clipView.frame = rect }
        // A restored pane can be populated before its host receives the
        // launch frame. AppKit does not reliably run the child's autoresizing
        // pass when the clip view is resized manually, so keep the content
        // frame in lockstep with the clip bounds here.
        let content = contentFrame(in: clipView.bounds)
        // A closing pane's hidden content keeps its frame: only its ground follows the collapsing frame.
        if !showsClosingGround, self.content.frame != content { self.content.frame = content }
        syncHeldArea()
        applyChromeShape()
    }

    /// Draw ahead (cmux-ad m26): the host will be `sizeChange` larger (negative: smaller) at its spring's next refresh. A
    /// key hold's area hands it to its followers (a terminal asks its renderer for that size now); its content's chrome
    /// does not change size in a spring, so the area changes by the same amount. In the key's turn (T-KEYS 3) the hold
    /// has not begun: the press's first refresh begins it (``isOnLayoutSpring``), and the area that hold will hold tells
    /// the followers it will hand that refresh's size now, so the frame that shows the press has their frames drawn.
    /// `keyPress`: false for a snapped structural change (``ScreenContentView`` `holdsSnapForContent`): its size goes to
    /// the renderer only, and its grid at the landing.
    func drawAhead(sizeChange: CGSize, keyPress: Bool) { // perf-hot: 1ms motion-frame
        if holdsUntilAfterLanding, let heldArea { return heldArea.drawAhead(sizeChange: sizeChange) }
        guard !holdsUntilAfterLanding, !isOnLayoutSpring, let area = (content as? PaneMotionHolding)?.paneMotionHoldArea else { return }
        area.drawAheadOfHold(sizeChange: sizeChange, keyPress: keyPress)
    }

    /// The held snap showed (``ScreenContentView`` `presentHeldSnap`): a size drawn ahead for it that its placement did
    /// not take goes (RESIZE P0 14).
    func snapDidShow() {
        (content as? PaneMotionHolding)?.paneMotionHoldArea?.aheadOfHoldShown()
    }

    /// The held snap shows in this turn (``ScreenContentView`` `presentHeldSnap`, RESIZE P0 21): the pane's content shows
    /// at its new size in the snap's commit (``PaneContentAreaView/aheadOfHoldWillShow()``).
    func snapWillShow() {
        (content as? PaneMotionHolding)?.paneMotionHoldArea?.aheadOfHoldWillShow()
    }

    /// Whether a key press's held snap must keep waiting for this pane's content drawn ahead for it (RESIZE P0 20,
    /// ``PaneContentAreaView/aheadOfHoldAwaitsContent(refreshesWaited:)``).
    func snapAwaitsContent(refreshesWaited: Int) -> Bool {
        (content as? PaneMotionHolding)?.paneMotionHoldArea?.aheadOfHoldAwaitsContent(refreshesWaited: refreshesWaited) ?? false
    }

    /// The held area rides the key hold's edges in each frame, and lets go when the hold ends, before the content hears
    /// the landing (its terminal then sizes its surface from its final frame).
    private func syncHeldArea() {
        guard let heldArea else { return }
        guard holdsUntilAfterLanding else {
            self.heldArea = nil
            // The area takes the frame it lets go at first (the content lays out at the frame `layoutClip` just gave it),
            // so held content changes size once, never first to the area's last spring frame (S1B).
            if window != nil, bounds.width >= 1, bounds.height >= 1 { content.layoutSubtreeIfNeeded() }
            heldArea.hold = nil
            return
        }
        let pin = heldPin ?? (trailing: false, bottom: false)
        heldArea.hold = PaneMotionHold(trailing: pin.trailing, bottom: pin.bottom)
    }

    /// The content's rounded corners and the ring's shape from the current
    /// clip frame and the content's header and footer. Changes no frame of the content.
    func applyChromeShape() {
        let framesContent = reporter?.paneFramesContent ?? true
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = framesContent || wholeCard ? cornerRadius : 0
        let rect = clipView.frame
        let (header, footer) = roundedBands
        let rounded = PaneChromeGeometry.roundedRect(inPadded: rect, headerHeight: header, footerHeight: footer)
        let radius = PaneChromeGeometry.cornerRadius(for: rounded, style: style)
        if showsClosingGround {
            clipView.setCornerRadius(radius) // a closing pane's ground keeps its pane's rounded corners (FRAME OWNER S3c)
        } else if let reporter, !wholeCard {
            clipView.setCornerRadius(0)
            reporter.setPaneContentCornerRadius(radius)
        } else {
            reporter?.setPaneContentCornerRadius(0)
            clipView.setCornerRadius(radius)
        }
        if chrome.showsContentFrame != framesContent {
            chrome.showsContentFrame = framesContent
            (superview as? ScreenContentView)?.paneFramingDidChange()
        }
        chrome.setShape(padding: padding, cornerRadius: style.paneCornerRadius, headerHeight: header, footerHeight: footer)
    }

    /// Tells the content (every ``PaneMotionTargeting`` view in it) how much larger its area will rest than
    /// it is now (`restSize` against the current frame, both less the padding): called by the screen once
    /// when a spring starts or retargets to a new size, never per frame.
    func announceRest() {
        guard let change = restSizeChange ?? returnedToHeldSize else { return }
        if heldArea != nil { announcedRest = restContentSize }
        heldAnchor = content.notifyPaneMotionWillRest(sizeChange: change)
    }

    /// FRAME OWNER S3 (a key hold whose containers follow): the content-area rest size the content last heard in this hold.
    private var announcedRest: CGSize?

    /// Zero when a key hold's rest went back to the size the hold began at after the content heard another (a press and
    /// its reverse in one hold): the content rests at that size, and hears it now, in the press's turn (one grid there,
    /// none at the landing). Nil otherwise.
    private var returnedToHeldSize: CGSize? {
        guard heldArea != nil, let announced = announcedRest, let rest = restContentSize,
              abs(announced.width - rest.width) >= 0.5 || abs(announced.height - rest.height) >= 0.5 else { return nil }
        return .zero
    }

    /// The content area at rest minus the size the content's producers have now (what the content hears,
    /// ``announceRest()``): in a key hold whose area holds, the content follows its pane and its producers (a terminal's
    /// surface, a Chromium page) are still at the size the hold began at.
    private var restSizeChange: CGSize? { restSizeChange(from: heldArea == nil ? content.frame.size : heldContentSize ?? content.frame.size) }

    /// The content area at rest (``restSize`` less the padding) minus `now`; nil without a rest size or with no change.
    private func restSizeChange(from now: CGSize) -> CGSize? {
        guard let rest = restContentSize else { return nil }
        let change = CGSize(width: rest.width - now.width, height: rest.height - now.height)
        guard abs(change.width) >= 0.5 || abs(change.height) >= 0.5 else { return nil }
        return change
    }

    private var restContentSize: CGSize? {
        guard let restSize else { return nil }
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        return PaneChromeGeometry.contentRect(forCell: CGRect(origin: .zero, size: restSize), style: style).size
    }

    /// `RestingPlacement`: the size change a view joining the content mid-spring will rest at, as the content heard it.
    var restContentSizeChange: CGSize? { isOnLayoutSpring ? restSizeChange : nil }
    /// `RestingPlacement`: the same from the content's frame now (it follows its pane in a key hold whose area holds).
    var liveRestContentSizeChange: CGSize? { isOnLayoutSpring ? restSizeChange(from: content.frame.size) : nil }

    /// The vertical edge a key hold's whole content rides, from the last ``announceRest()`` (nil: the near-edge rule).
    private var heldAnchor: PaneMotionAnchor?

    /// Tells the content when the pane's frame in the window changed.
    func noteWindowFrame() {
        guard let reporter, window != nil else { return }
        let frame = convert(bounds, to: nil)
        guard frame != lastWindowFrame else { return }
        lastWindowFrame = frame
        reporter.paneFrameInWindowDidChange()
    }

    /// Clips the host to `rect` (its own coordinates) where a docked docked
    /// column covers it; nil removes the clip. `cutouts` (its own coordinates)
    /// are the parts a pane in front covers that `rect` cannot leave out (a
    /// corner): the mask carries them for a Chromium page, which no view order
    /// reaches (`StripClipMaskLayer.cutouts`).
    /// Returns true when the clip changed: a Chromium page in this pane then
    /// re-reads its clip shape, which carries this mask (`CEFClipShape`).
    /// The part of this host (own coordinates) that takes clicks while it sits in a scroll area
    /// (scroll-areas-DESIGN.md): what scrolled out of the area's window is masked away and must
    /// not take clicks meant for the view beside the area. Nil outside an area.
    var areaHitClip: CGRect?

    override func hitTest(_ point: NSPoint) -> NSView? {
        if showsClosingGround { return nil }
        if let areaHitClip, !areaHitClip.contains(convert(point, from: superview)) { return nil }
        return super.hitTest(point)
    }

    @discardableResult
    func setStripClip(_ rect: CGRect?, cutouts: [CGRect] = []) -> Bool {
        guard let layer else { return false }
        guard let rect else {
            guard layer.mask != nil else { return false }
            layer.mask = nil
            return true
        }
        let mask = (layer.mask as? StripClipMaskLayer) ?? {
            let mask = StripClipMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            layer.mask = mask
            return mask
        }()
        guard mask.frame != rect || mask.cutouts != cutouts || mask.backgroundColor == nil && cutouts.isEmpty else { return false }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.place(rect, cutouts: cutouts, scale: layer.contentsScale)
        CATransaction.commit()
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
