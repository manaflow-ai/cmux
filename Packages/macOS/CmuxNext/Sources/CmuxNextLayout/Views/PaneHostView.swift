import AppKit
import CmuxNextDesign
import QuartzCore

/// Wraps one App-provided pane view. The content sits in `clipView`, the
/// cell inset by the pane padding. A view that reports a header
/// (`PaneContentChrome`: the tab strip, a browser toolbar) rounds its own
/// content area and the chrome traces that area only; any other view is
/// clipped to a rounded rect here, header and all. Layer clips take the
/// Ghostty Metal layer and WebKit along; Chromium pages are child windows
/// no clip reaches, so the browser module reads the rounded ancestor and
/// masks the page itself.
///
/// The focus ring, border and inactive dim (`chrome`) live in the layout's
/// `OverlayPlane`, not in this view, so they draw above content that is a
/// child window (Chromium pages); the root keeps them on this view's
/// displayed frame.
final class PaneHostView: NSView {
    let pane: PaneID
    let content: NSView
    let chrome = PaneOverlayView()
    private let clipView = PaneClipView()
    private(set) var padding: CGFloat = 0
    private(set) var cornerRadius: CGFloat = 0
    private var reporter: PaneContentChrome? { content as? PaneContentChrome }
    private var lastWindowFrame: CGRect?

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
        reporter?.onPaneHeaderHeightChange = { [weak self] in self?.layoutClip() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    /// Whether the pane sits in a sticky (docked) column: it then shows the
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

    /// The padded rect the content view fills, in this view's coordinates.
    var contentRect: CGRect { clipView.frame }

    /// The rounded area the border and ring trace: below the content's
    /// header, or the whole padded rect for content without one.
    var roundedRect: CGRect {
        PaneChromeGeometry.roundedRect(inPadded: clipView.frame, headerHeight: reporter?.paneHeaderHeight ?? 0)
    }

    /// Applies the pane padding and corner radius (live style values).
    func applyShape(padding: CGFloat, cornerRadius: CGFloat) {
        guard padding != self.padding || cornerRadius != self.cornerRadius else { return }
        self.padding = padding
        self.cornerRadius = cornerRadius
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
        let header = reporter?.paneHeaderHeight ?? 0
        let radius = PaneChromeGeometry.cornerRadius(for: PaneChromeGeometry.roundedRect(inPadded: rect, headerHeight: header), style: style)
        if let reporter {
            clipView.setCornerRadius(0)
            reporter.setPaneContentCornerRadius(radius)
        } else {
            clipView.setCornerRadius(radius)
        }
        chrome.setShape(padding: padding, cornerRadius: cornerRadius, headerHeight: header)
    }

    /// Tells the content when the pane's frame in the window changed.
    func noteWindowFrame() {
        guard let reporter, window != nil else { return }
        let frame = convert(bounds, to: nil)
        guard frame != lastWindowFrame else { return }
        lastWindowFrame = frame
        reporter.paneFrameInWindowDidChange()
    }

    /// Clips the host to `rect` (its own coordinates) where a docked sticky
    /// column covers it; nil removes the clip.
    func setStripClip(_ rect: CGRect?) {
        guard let layer else { return }
        guard let rect else {
            if layer.mask != nil { layer.mask = nil }
            return
        }
        let mask = layer.mask ?? {
            let mask = CALayer()
            mask.backgroundColor = NSColor.black.cgColor
            layer.mask = mask
            return mask
        }()
        guard mask.frame != rect else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = rect
        CATransaction.commit()
    }

    func setChrome(showsRing: Bool, dim: CGFloat, focusRing: FocusRingSettings, ringAlphaOverride: CGFloat? = nil,
                   tabEmphasis: ChromeEmphasis = .full, border: PaneOverlayView.Border, attention: AttentionMark?,
                   attentionSettings: AttentionSettings, animated: Bool) {
        reporter?.setChromeEmphasis(tabEmphasis, animated: animated)
        chrome.update(showsRing: showsRing, dim: dim, focusRing: focusRing, ringAlphaOverride: ringAlphaOverride, border: border,
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

    override var isFlipped: Bool { true }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }
}
