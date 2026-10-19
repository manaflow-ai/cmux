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
    private var stripCutouts: [CGRect] = []

    init(pane: PaneID, content: NSView) {
        self.pane = pane
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        clipView.frame = bounds
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

    /// Whether the pane sits in a docked (docked) column: it then shows the
    /// user's docks background under its content (`appearance.surfaces.docks`).
    /// What of the host shows while a spring rect reveals it (a split's arriving pane, a zooming
    /// one; superview coordinates); nil, its whole frame. Panes under it are clipped by this.
    var revealRect: CGRect?
    /// Where the focus ring, border and dim go (superview coordinates) while that is not the host's
    /// frame: a zooming pane's presented rect (its host keeps the full screen's size). Nil: the frame.
    var chromeFrame: CGRect?
    /// Where the host will rest minus where it shows now (`RestingPlacement`): its spring rect's
    /// target and the strip camera's target, against the presented frame. Zero at rest; coming
    /// to rest tells the content, whose window-relative chrome held its motion layout.
    var restOffset: CGVector = .zero {
        didSet { if restOffset == .zero, oldValue != .zero, window != nil { reporter?.paneFrameInWindowDidChange() } }
    }

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
        super.setFrameSize(newSize)
        layoutClip()
    }

    private func layoutClip() {
        var style = LayoutStyle()
        style.panePadding = padding
        style.paneCornerRadius = cornerRadius
        let rect = PaneChromeGeometry.contentRect(forCell: bounds, style: style)
        if clipView.frame != rect { clipView.frame = rect }
        // A restored pane can be populated before its host receives the
        // launch frame. AppKit does not reliably run the child's autoresizing
        // pass when the clip view is resized manually, so keep the content
        // frame in lockstep with the clip bounds here.
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
    @discardableResult
    func setStripClip(_ rect: CGRect?, cornerRadius: CGFloat = 0, cutouts: [CGRect] = []) -> Bool {
        guard let layer else { return false }
        guard let rect else {
            guard layer.mask != nil else { return false }
            layer.mask = nil
            stripCutouts = []
            return true
        }
        let mask = layer.mask ?? {
            let mask = StripClipMaskLayer()
            mask.name = CALayer.cmuxStripClipName
            mask.backgroundColor = NSColor.black.cgColor
            layer.mask = mask
            return mask
        }()
        guard mask.frame != rect || mask.cornerRadius != cornerRadius || stripCutouts != cutouts else { return false }
        stripCutouts = cutouts
        (mask as? StripClipMaskLayer)?.cutouts = cutouts
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = rect
        mask.cornerRadius = cornerRadius
        CATransaction.commit()
        return true
    }

    func setChrome(showsRing: Bool, dim: CGFloat, dimFill: PaneOverlayView.DimFill = .pane, focusRing: FocusRingSettings,
                   ringAlphaOverride: CGFloat? = nil, tabEmphasis: ChromeEmphasis = .full, border: PaneOverlayView.Border,
                   attention: AttentionMark?, attentionSettings: AttentionSettings, animated: Bool) {
        reporter?.setChromeEmphasis(tabEmphasis, animated: animated)
        chrome.update(showsRing: showsRing, dim: dim, dimFill: dimFill, focusRing: focusRing, ringAlphaOverride: ringAlphaOverride, border: border,
                      attention: attention, attentionSettings: attentionSettings, animated: animated)
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
