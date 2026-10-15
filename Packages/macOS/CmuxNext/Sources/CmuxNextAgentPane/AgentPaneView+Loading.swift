import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The pane's first frame (cx-sj96): from the moment it is made until its page draws what it is
/// (`pane.painted`: the handshake's answer or the host's error), the pane shows its page
/// background with the shared loading mark, drawn natively, and keeps the page clear. A new chat
/// is never an empty pane while its page loads (about 0.4 s) and acpmux starts (as long as the
/// daemon takes), and never shows the page's frames before the handshake. A chat's page then fades
/// in over it (Leo 2026-10-14, as the Claude app switches to a chat it had not loaded: quick but
/// seen); a New Tab page replaces it in one step.
final class AgentPaneLoadingView: NSView {
    /// The shared busy mark (`appearance.statusIndicator.style`; `none` draws only the background).
    let indicator = StatusIndicatorView()
    static let markSide: CGFloat = 18
    /// How long the mark waits: a page that paints sooner shows only its background before it
    /// fades in, never a mark that pops up and goes.
    static let markDelay: Duration = .milliseconds(500)
    private let markTimer = DemandTimer(owner: "agentPane.loadingMark")
    /// What waits for the page to show (``AgentPaneView/whenRevealed(_:)``).
    var revealWaiters: [() -> Void] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        addSubview(indicator)
        indicator.configure(.busy(progress: nil))
        indicator.isHidden = true
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

    /// Shows the mark after ``markDelay``, unless the page paints first.
    func showMarkLater() {
        indicator.isHidden = true
        markTimer.schedule(after: Self.markDelay) { @MainActor [weak self] in self?.indicator.isHidden = false }
    }

    func hideMark() {
        markTimer.cancel()
        indicator.isHidden = true
    }

    /// The page shows: everything waiting for it runs.
    func revealed() {
        let waiters = revealWaiters
        revealWaiters = []
        for waiter in waiters { waiter() }
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
        loadingView.frame = topBar.contentFrame(in: bounds)
        addSubview(loadingView, positioned: .above, relativeTo: nil)
        themeLoadingState(themeTokens)
        loadingView.showMarkLater()
        model.whenPainted { [weak self] in self?.endLoadingState() }
    }

    /// The page shows and the loading state goes. A chat fades in, in ``MotionFade/fadeIn``: its
    /// background fades out over the page, or the page fades in over its last frame's image (the
    /// pane's launch image, cleared once this ends, ``whenRevealed(_:)``). A New Tab page shows in
    /// one frame (b235e5f5d752). A chat already shown never gets here: it painted once and draws
    /// no loading state again, so switching back to it is instant.
    func endLoadingState() {
        loadingView.hideMark()
        let overImage = !showsLoadingState
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if model.newTab != nil || !overImage { pageContent.alphaValue = 1 }
        CATransaction.commit()
        guard model.newTab == nil else { return finishLoadingState() }
        Motion.animate(.fadeIn, in: self, {
            if overImage { pageContent.animator().alphaValue = 1 } else { loadingView.animator().alphaValue = 0 }
        }, completion: { [weak self] in self?.finishLoadingState() })
    }

    private func finishLoadingState() {
        pageContent.alphaValue = 1
        loadingView.removeFromSuperview()
        loadingView.alphaValue = 1
        loadingView.revealed()
    }

    /// Runs `body` once the page shows: at once for a page that shows, else once its loading
    /// state has gone (after its fade).
    public func whenRevealed(_ body: @escaping () -> Void) {
        if loadingView.superview != nil { return loadingView.revealWaiters.append(body) }
        if model.hasPainted { return body() }
        model.whenPainted(body)
    }

    func themeLoadingState(_ tokens: ThemeTokens) {
        guard loadingView.superview != nil else { return }
        loadingView.paint(AgentPaneTheme.underPageColor(tokens, surface: surfaceKind).nsColor)
    }
}
