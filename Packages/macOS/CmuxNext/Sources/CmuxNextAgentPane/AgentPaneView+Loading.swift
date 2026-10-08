import AppKit
import CmuxNextDesign

/// The pane's first frame (cx-sj96): from the moment it is made until its page draws what it is
/// (`pane.painted`: the handshake's answer or the host's error), the pane shows its page
/// background with the shared loading mark, drawn natively, and keeps the page clear. A new chat
/// is never an empty pane while its page loads (about 0.4 s) and acpmux starts (as long as the
/// daemon takes), and never shows the page's frames before the handshake. The page's first frame
/// replaces it in one step.
final class AgentPaneLoadingView: NSView {
    /// The shared busy mark (`appearance.statusIndicator.style`; `none` draws only the background).
    let indicator = StatusIndicatorView()
    static let markSide: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        addSubview(indicator)
        indicator.configure(.busy(progress: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(Self.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let side = Self.markSide
        indicator.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(),
                                 width: side, height: side)
    }

    /// The page's background, so the pane looks like the page it becomes.
    func paint(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }
}

extension AgentPaneView {
    /// The page's view: the shared page host's, or this pane's own web view.
    var pageContent: NSView { page.map { $0 as NSView } ?? webView }

    /// Whether the pane draws its loading state until the page paints. A pane over its last
    /// page's image (a relaunch, `AgentPaneLaunchImages`) turns it off: that image is its first
    /// frame, and the pane stays clear above it. No effect once the page has painted.
    public var showsLoadingState: Bool {
        get { loadingView.superview != nil && !loadingView.isHidden }
        set { loadingView.isHidden = !newValue }
    }

    /// Shows the loading state over a page that has not painted; the page's first frame ends it.
    func beginLoadingState() {
        guard !model.hasPainted else { return }
        pageContent.alphaValue = 0
        loadingView.frame = bounds
        addSubview(loadingView, positioned: .above, relativeTo: nil)
        themeLoadingState(themeTokens)
        model.whenPainted { [weak self] in self?.endLoadingState() }
    }

    /// The page shows and the loading state goes, in one frame.
    func endLoadingState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageContent.alphaValue = 1
        loadingView.removeFromSuperview()
        CATransaction.commit()
    }

    func themeLoadingState(_ tokens: ThemeTokens) {
        guard loadingView.superview != nil else { return }
        loadingView.paint(AgentPaneTheme.underPageColor(tokens, surface: surfaceKind).nsColor)
    }
}
