public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The pane's first frame (cx-sj96): from the moment it is made until its page draws what it is
/// (`pane.painted`: the handshake's answer or the host's error), the pane shows its page
/// background with the shared loading mark, drawn natively, and keeps the page clear. A new chat
/// is never an empty pane while its page loads (about 0.4 s) and acpmux starts (as long as the
/// daemon takes), and never shows the page's frames before the handshake. A chat's page then fades
/// in over it (Leo 2026-10-14, as the Claude app switches to a chat it had not loaded: quick but
/// seen); a New Tab page replaces it in one step.
public final class AgentPaneLoadingView: NSView {
    /// The shared busy mark (`appearance.statusIndicator.style`; `none` draws only the background).
    let indicator = StatusIndicatorView()
    static let markSide: CGFloat = 18
    /// How long the mark waits: a page that paints sooner shows only its background before it
    /// fades in, never a mark that pops up and goes. Longer than a pane's hold on the chat it
    /// showed (`PanePaintHold.limit`), so the mark never shows the moment a hold gives up.
    static let markDelay: Duration = .milliseconds(800)
    /// Placeholder until the fix: the loading state has no deadline yet (cx-txnr).
    static var paintLimit: Duration = .seconds(8)
    private let markTimer = DemandTimer(owner: "agentPane.loadingMark")
    private var revealWaiters: [() -> Void] = []
    /// While it fades out over the page, clicks and scrolls go to the page.
    private var leaving = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        autoresizingMask = [.width, .height]
        indicator.configure(.busy(progress: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(Self.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public var isFlipped: Bool { true }

    override public func hitTest(_ point: NSPoint) -> NSView? { leaving ? nil : super.hitTest(point) }

    override public func layout() {
        super.layout()
        let side = Self.markSide
        indicator.frame = NSRect(x: ((bounds.width - side) / 2).rounded(), y: ((bounds.height - side) / 2).rounded(),
                                 width: side, height: side)
    }

    /// The page's background, so the pane looks like the page it becomes.
    func paint(_ color: NSColor) {
        layer?.backgroundColor = color.cgColor
    }

    /// Shows the mark after ``markDelay``, unless the page paints first. Out of the view until then:
    /// the indicator sets its own `isHidden` from its config whenever it refreshes.
    func showMarkLater() {
        markTimer.schedule(after: Self.markDelay) { @MainActor [weak self] in
            guard let self else { return }
            addSubview(indicator)
        }
    }

    func hideMark() {
        markTimer.cancel()
        indicator.removeFromSuperview()
    }

    /// Runs `body` once the page shows: after its fade, if it fades; now if it shows. It
    /// shows once this has left the pane, which it joins before the page can paint.
    public func whenRevealed(_ body: @escaping () -> Void) {
        if superview == nil { body() } else { revealWaiters.append(body) }
    }

    /// Leaves over `page`, which stayed clear under it. Fading, in ``MotionFade/fadeIn``: this
    /// background fades out over the page, or, hidden over the pane's last frame of the page (a
    /// launch image, cleared once this ends), the page fades in over that. A chat already shown
    /// never gets here: it draws no loading state again, so switching back to it is instant.
    func leave(over page: NSView, fades: Bool) {
        hideMark()
        leaving = true
        let overImage = isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !fades || !overImage { page.alphaValue = 1 }
        CATransaction.commit()
        guard fades else { return left(page) }
        Motion.animate(.fadeIn, in: self, {
            if overImage { page.animator().alphaValue = 1 } else { animator().alphaValue = 0 }
        }, completion: { [weak self, weak page] in self?.left(page) })
    }

    private func left(_ page: NSView?) {
        page?.alphaValue = 1
        leaving = false
        removeFromSuperview()
        alphaValue = 1
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
        set { if !model.hasPainted { loadingView.isHidden = !newValue } }
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

    /// The page shows and the loading state goes (``AgentPaneLoadingView/leave(over:fades:)``): a
    /// chat fades in, a New Tab page or a page a pane holds hidden for its swap shows in one frame.
    func endLoadingState() { loadingView.leave(over: pageContent, fades: model.newTab == nil && alphaValue > 0) }

    func themeLoadingState(_ tokens: ThemeTokens) {
        guard loadingView.superview != nil else { return }
        loadingView.paint(AgentPaneTheme.underPageColor(tokens, surface: surfaceKind).nsColor)
    }
}
