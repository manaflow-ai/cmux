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

    /// Whether content keeps its size while the host is on a layout spring (`motion.pane.holdContent`, off by
    /// default: live resize). Injected so tests pin it without the shared tunable store.
    private let holdsContentInMotion: () -> Bool
    /// True only for a content handoff: its first spring frame already has the narrower
    /// destination size, so the held page must start at that target. Ordinary moves (including
    /// an unzooming chat) keep their painted size even when their rest offset is nonzero.
    var isContentHandoff = false

    init(pane: PaneID, content: NSView, holdsContentInMotion: @escaping () -> Bool = { LayoutTunables.holdsContentInMotion.value }) {
        self.pane = pane
        self.content = content
        self.holdsContentInMotion = holdsContentInMotion
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        clipView.frame = bounds
        // `layoutClip` places the content itself: autoresizing would resize held content on every
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
                guard holdsContentInMotion() else {
                    heldContentSize = nil
                    return
                }
                // A handoff pane starts its spring by moving to a narrower final frame. Its
                // content was still full-width when this flag was set; use the target content
                // size for that first frame so the handoff never replays a resize at landing.
                if isContentHandoff, let rest = restContentSize, content.frame.width > rest.width {
                    heldContentSize = rest
                } else {
                    heldContentSize = content.frame.size
                }
            } else {
                heldContentSize = nil
                heldAnchor = nil
                // The one layout at the size the spring landed at, before the content hears it landed.
                layoutClip()
                content.notifyPaneMotionSettled()
                isContentHandoff = false
            }
        }
    }

    /// The host's size at rest (its spring rect's target), set with ``restOffset`` on every
    /// presented frame; nil before the screen first places it.
    var restSize: CGSize?

    /// The content's size when the current layout spring started; nil at rest or with
    /// `LayoutTunables.holdsContentInMotion` off.
    private var heldContentSize: CGSize?

    /// The content's frame in the clip: the clip's bounds at rest. On a layout spring it keeps the
    /// larger of its size when the spring started and its size at rest (Leo 2026-10-20: a panel
    /// opening beside a chat lagged, the chat reflowing on every frame), so a page or a terminal
    /// lays out once and the clip shows what each frame shows. It is pinned at the edge nearer its
    /// rest, so it rides that edge: a pane opening on the right slides in from the right while the
    /// chat keeps its width under it until the spring lands.
    /// A host at its rest place and size holds nothing, whatever its spring flag says.
    private func contentFrame(in clip: CGRect) -> CGRect {
        guard let held = heldContentSize, let restSize, restOffset != .zero || frame.size != restSize else { return clip }
        // The clip at rest, from the rest cell itself: a frame narrower than twice the padding
        // (a new pane's first frames) has a zero clip, and the clip's growth then is no measure of
        // the rest, so the page would shrink and resize on every one of those frames.
        let rest = clipRect(forCell: CGRect(origin: .zero, size: restSize)).size
        let size = CGSize(width: max(clip.width, held.width, rest.width), height: max(clip.height, held.height, rest.height))
        // The far edge's distance from its rest against the near edge's (`restOffset`).
        let trailing = abs(restOffset.dx + restSize.width - frame.width) < abs(restOffset.dx) - 0.5
        let bottom = heldAnchor.map { $0 == .bottom } ?? (abs(restOffset.dy + restSize.height - frame.height) < abs(restOffset.dy) - 0.5)
        return CGRect(x: trailing ? clip.maxX - size.width : clip.minX,
                      y: bottom == isFlipped ? clip.maxY - size.height : clip.minY,
                      width: size.width, height: size.height)
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
        // (held content is pinned by the rest offset, which a move changes: it lays out).
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

    private func layoutClip() {
        clipLayouts += 1
        let rect = clipRect(forCell: bounds)
        if clipView.frame != rect { clipView.frame = rect }
        // A restored pane can be populated before its host receives the
        // launch frame. AppKit does not reliably run the child's autoresizing
        // pass when the clip view is resized manually, so keep the content
        // frame in lockstep with the clip bounds here.
        let content = contentFrame(in: clipView.bounds)
        if self.content.frame != content { self.content.frame = content }
        applyChromeShape()
    }

    /// The content's rounded corners and the ring's shape from the current
    /// clip frame and the content's header and footer. Changes no frame.
    private func applyChromeShape() {
        let framesContent = reporter?.paneFramesContent ?? true
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = framesContent || wholeCard ? cornerRadius : 0
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
        chrome.showsContentFrame = framesContent
        chrome.setShape(padding: padding, cornerRadius: style.paneCornerRadius, headerHeight: header, footerHeight: footer)
    }

    /// Tells the content (every ``PaneMotionTargeting`` view in it) how much larger its area will rest than
    /// it is now (`restSize` against the current frame, both less the padding): called by the screen once
    /// when a spring starts or retargets to a new size, never per frame.
    func announceRest() {
        guard let change = restSizeChange else { return }
        heldAnchor = content.notifyPaneMotionWillRest(sizeChange: change)
        if heldContentSize != nil {
            // A close can retarget a running spring to a wider pane, then an early reopen can
            // retarget it back before the first spring lands. Keep the largest painted content
            // size seen by this motion so the second target does not reflow the page on every frame.
            if let held = heldContentSize, let rest = restContentSize {
                heldContentSize = CGSize(width: max(held.width, rest.width),
                                         height: max(held.height, rest.height))
            }
            layoutClip()
        }
    }

    /// The content area at rest (``restSize`` less the padding) minus the content's size now; nil without a
    /// rest size or with no change.
    private var restSizeChange: CGSize? {
        guard let rest = restContentSize else { return nil }
        let now = content.frame.size
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

    /// `RestingPlacement`: the size change a view joining the content mid-spring will rest at.
    var restContentSizeChange: CGSize? { isOnLayoutSpring ? restSizeChange : nil }

    /// The vertical edge held content rides, from the last ``announceRest()`` (nil: the near-edge rule).
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

/// The rounded clip around a pane's content. `masksToBounds` with a corner
/// radius clips every sublayer, Metal layers included. Corners are circular
/// (not continuous) so the Chromium page mask, a circular-arc path built
/// from this layer's radius, matches them exactly.
final class PaneClipView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    nonisolated override var isFlipped: Bool { true }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }
}
