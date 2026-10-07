import AppKit
import CmuxNextDesign

/// The New Tab page over the pane's previous content, blurred and dimmed (Lawrence's reference,
/// CleanShot 2026-10-05 10.35.34 PM): the previous content view stays where it is, under a
/// within-window blur and a dim of the pane's own background token, and the page (transparent on
/// the New Tab surface, AgentPaneTheme) draws over both. Nothing is captured or copied: the blur
/// samples the content's last frame (a hidden terminal stops rendering and keeps it), so showing
/// the page costs no snapshot. A translucent window shows its own backdrop through the page, so it
/// gets none. Any other content shown in the pane, or the page becoming a chat, removes it.
extension PaneContentView {
    /// The page shown over `hosted`, the content shown until now: true when `hosted` stays in
    /// place as its backdrop. A backdrop already there stays (a page over a page shows the
    /// content before the first one), and the page it replaces leaves.
    func keepsBackdrop(_ hosted: NSView) -> Bool {
        defer { placeFrost() }
        guard WindowBackdrop(themeTokens).panesPaintBackground, !hasBackdrop else { return false }
        underlay = hosted
        // It no longer moves this pane's strip (the page's header is the pane's).
        (hosted as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        return true
    }

    /// The backdrop is in this pane (another pane may have taken its view, a moved tab).
    var hasBackdrop: Bool { underlay.map { $0.superview === contentHost } ?? false }

    /// Removes the backdrop. `view`, shown next, stays when it was the backdrop (the previous
    /// tab selected again: it is already in place, with nothing over it).
    func dropBackdrop(keeping view: NSView?) {
        frost?.removeFromSuperview()
        frost = nil
        if let underlay, underlay !== view, underlay.superview === contentHost { underlay.removeFromSuperview() }
        underlay = nil
    }

    /// The frost right above the backdrop, at the content's size; none without a backdrop.
    func placeFrost() {
        guard let underlay, hasBackdrop else {
            frost?.removeFromSuperview()
            frost = nil
            return
        }
        let frost = frost ?? NewTabFrostView()
        self.frost = frost
        frost.dim = performWithTheme { Palette.surfaceBackground }
        frost.frame = contentHost.bounds
        frost.autoresizingMask = [.width, .height]
        if frost.superview !== contentHost { contentHost.addSubview(frost, positioned: .above, relativeTo: underlay) }
    }
}

/// A within-window blur of what is under it, with the theme's background over it at
/// ``dimAlpha``. Never hit, never in the accessibility tree.
final class NewTabFrostView: NSView {
    /// How much of the pane's background covers the blurred content.
    static let dimAlpha: CGFloat = 0.62
    private let blur = NSVisualEffectView()
    private let tint = NSView()

    /// The pane's background token; drawn at ``dimAlpha``.
    var dim: NSColor = .clear {
        didSet { tint.layer?.backgroundColor = dim.withAlphaComponent(Self.dimAlpha).cgColor }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        blur.blendingMode = .withinWindow
        blur.material = .hudWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        tint.wantsLayer = true
        tint.autoresizingMask = [.width, .height]
        addSubview(tint)
        setAccessibilityElement(false)
        setAccessibilityHidden(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        blur.frame = bounds
        tint.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
}
