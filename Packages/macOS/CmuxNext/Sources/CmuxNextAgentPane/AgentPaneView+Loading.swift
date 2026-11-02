public import AppKit
import CmuxNextDesign
import CmuxNextPages
import CmuxNextWakeups
import os

private let loadingLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")

/// The pane's first frame (cx-sj96): from the moment it is made until its page draws what it is
/// (`pane.painted`: the handshake's answer or the host's error), the pane shows its page
/// background with the shared loading mark, drawn natively, and keeps the page clear. A new chat
/// is never an empty pane while its page loads (about 0.4 s) and acpmux starts (as long as the
/// daemon takes), and never shows the page's frames before the handshake. A chat read cold then
/// fades in over it (Leo 2026-10-14, as the Claude app switches to a chat it had not loaded: quick
/// but seen); a chat the page drew from a kept tail and a New Tab page replace it in one step
/// (``AgentPaneView/pageFades(hasNewTab:isVisible:fromKeptTail:)``).
public final class AgentPaneLoadingView: NSView {
    /// The shared busy mark (`appearance.statusIndicator.style`; `none` draws only the background).
    let indicator = StatusIndicatorView.spinner()
    static let markSide: CGFloat = 18
    /// How long the mark waits: a page that paints sooner shows only its background before it
    /// fades in, never a mark that pops up and goes. Longer than a pane's hold on the chat it
    /// showed (`PanePaintHold.limit`), so the mark never shows the moment a hold gives up.
    static let markDelay: Duration = .milliseconds(800)
    /// How often the loading state checks on a page that has not painted (cx-txnr): WebKit
    /// holds the animation frames of a page it thinks is not visible (a window occluded at a
    /// relaunch), and its `pane.painted` may then never come. Seen unpainted at ``silentChecks``
    /// checks in a row, the page counts as painted and shows as it is: like the pane's
    /// other covers (`PanePaintHold.limit`, the launch image), it never stays for good. Out of
    /// sight (a parked spare, a hidden tab, a window ordered out) it waits.
    var paintCheckInterval: Duration = .seconds(4) {
        didSet { if onGiveUp != nil { schedulePaintCheck() } }
    }
    /// How many checks in sight a page that has said nothing at all gets before it shows as it is.
    static let silentChecks = 2
    /// How many a page that has answered the handshake gets, counted from the handshake. A page
    /// whose bridge is up is not the stuck case this give-up is for: it is waiting on its own
    /// chat, and it reports its first paint by `CHAT_DRAW_HOLD_MS` (10 s after the handshake,
    /// acpmux/App.tsx) whether the chat arrived or not. Revealing it before its own deadline
    /// showed Leo a chat that painted, went black for seconds, then came back (2026-10-22), so
    /// this bound clears that 10 s page budget. Counted from the handshake rather than from the pane,
    /// because a slow daemon can answer at any point inside the silent bound; the cost is that a
    /// page that handshakes and then truly hangs holds a spinner for this long after it spoke.
    static let aliveChecks = 3
    private let markTimer = DemandTimer(owner: "agentPane.loadingMark")
    private let paintTimer = DemandTimer(owner: "agentPane.paintCheck")
    private var onGiveUp: (@MainActor () -> Void)?
    /// Whether the page's bridge is up: it answered the handshake, so it speaks for itself.
    var pageIsAlive: (@MainActor () -> Bool)?
    /// How many checks in a row have seen the pane, still unpainted.
    private var seenUnpainted = 0
    /// Whether a check has already seen the page answer, so the count starts over only once.
    private var sawAlive = false
    private var revealWaiters: [() -> Void] = []
    /// While it fades out over the page, clicks and scrolls go to the page.
    private var leaving = false
    #if DEBUG || CMUX_BENCH_HOOKS
    var isLeaving: Bool { leaving }
    #endif
    /// Whether the page was asked to fade in when this left, nil until it has. The decision, not
    /// what was drawn of it: with motion off a fade and no fade both end in one frame, so this is
    /// the only way a test on a headless host can tell them apart.
    private(set) var leftFading: Bool?

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

    /// Runs `giveUp` once the pane has been seen unpainted at ``silentChecks`` checks in a row, or
    /// ``aliveChecks`` while ``pageIsAlive`` answers true, unless the loading state leaves first.
    func giveUpWhenSeenUnpainted(_ giveUp: @escaping @MainActor () -> Void) {
        onGiveUp = giveUp
        seenUnpainted = 0
        sawAlive = false
        schedulePaintCheck()
    }

    private func schedulePaintCheck() {
        paintTimer.schedule(after: paintCheckInterval) { @MainActor [weak self] in self?.checkPaint() }
    }

    private func checkPaint() {
        guard superview != nil, !leaving, let giveUp = onGiveUp else { return }
        // Out of sight the count starts over: the checks measure time the page had on screen to
        // paint, not time since the pane was made.
        seenUnpainted = paneIsSeen ? seenUnpainted + 1 : 0
        // Read at the check, not when this was armed: a page handshakes while the count runs. The
        // first check that sees it answer starts the count over, so its budget runs from the
        // handshake however late in the silent bound that landed.
        let alive = pageIsAlive?() == true
        if alive, !sawAlive {
            sawAlive = true
            seenUnpainted = 0
        }
        if seenUnpainted >= (alive ? Self.aliveChecks : Self.silentChecks) {
            onGiveUp = nil
            giveUp()
            return
        }
        schedulePaintCheck()
    }

    /// The pane is on screen: its window is ordered in, and the pane is neither hidden nor
    /// outside the window's content (a parked New Tab spare). Not the window's occlusion state:
    /// WebKit's own view of it is what holds the paint.
    private var paneIsSeen: Bool {
        guard let pane = superview, let window, window.isVisible, let content = window.contentView,
              !pane.isHiddenOrHasHiddenAncestor else { return false }
        // Window coordinates: `visibleRect` does not clip to views that do not clip to bounds.
        return pane.convert(pane.bounds, to: nil).intersects(content.convert(content.bounds, to: nil))
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
        // Once: the page's paint can follow the deadline's leave.
        guard superview != nil, !leaving else { return }
        paintTimer.cancel()
        onGiveUp = nil
        pageIsAlive = nil
        hideMark()
        leaving = true
        leftFading = fades
        let overImage = isHidden
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !fades || !overImage { page.alphaValue = 1 }
        PageWebView.syncChromiumVisibility(in: page)
        CATransaction.commit()
        guard fades else { return left(page) }
        Motion.home.animate(.fadeIn, in: self, {
            if overImage { page.animator().alphaValue = 1 } else { animator().alphaValue = 0 }
            PageWebView.syncChromiumVisibility(in: page)
        }, completion: { [weak self, weak page] in self?.left(page) })
    }

    private func left(_ page: NSView?) {
        page?.alphaValue = 1
        if let page { PageWebView.syncChromiumVisibility(in: page) }
        leaving = false
        #if DEBUG || CMUX_BENCH_HOOKS
        // Still in its pane: the pane's trace takes it.
        ChatOpenTrace.shared.mark(.loadingLeft, view: self)
        #endif
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
        loadingView.pageIsAlive = { [weak self] in self?.model.hasHandshake ?? false }
        #if DEBUG || CMUX_BENCH_HOOKS
        ChatOpenTrace.shared.bind(view: self, page: page, surface: { [weak self] in self?.traceSurface ?? .gone },
                                  engine: { [weak self] in self?.engineName ?? "gone" })
        #endif
        loadingView.giveUpWhenSeenUnpainted { [weak self] in
            guard let self, !model.hasPainted else { return }
            loadingLogger.error("agent pane page did not report its first paint in sight; showing it")
            model.markPainted()
        }
    }

    /// The page shows and the loading state goes (``AgentPaneLoadingView/leave(over:fades:)``).
    func endLoadingState() {
        #if DEBUG || CMUX_BENCH_HOOKS
        // The handshake's painted answer ends the loading state in the same turn.
        ChatOpenTrace.shared.mark(.panePainted, view: self)
        ChatOpenTrace.shared.mark(.loadingLeave, view: self)
        #endif
        loadingView.leave(over: pageContent,
                          fades: Self.pageFades(hasNewTab: model.newTab != nil, isVisible: alphaValue > 0,
                                                fromKeptTail: model.paintedFromKeptTail))
    }

    /// Whether the page fades in over the loading state or simply shows.
    ///
    /// A chat read cold fades (Leo 2026-10-14, as the Claude app switches to a chat it had not
    /// loaded: quick but seen). A chat the page drew from a kept tail does not: those rows are on
    /// screen in the frame the open landed on (tailCache.ts, ``AgentPaneTailCache``), and a 120 ms
    /// fade over them is softness on the one open that is instant — "instant if cached" (Leo
    /// 2026-10-20). A New Tab page, and a page a pane holds hidden for its swap, show in one frame
    /// as they did before.
    static func pageFades(hasNewTab: Bool, isVisible: Bool, fromKeptTail: Bool) -> Bool {
        !hasNewTab && isVisible && !fromKeptTail
    }

    func themeLoadingState(_ tokens: ThemeTokens) {
        guard loadingView.superview != nil else { return }
        // In this view's scope: over its workspace's picture the loading state stays clear (#28867).
        loadingView.paint(performWithTheme { AgentPaneTheme.underPageColor(tokens, surface: surfaceKind) }.nsColor)
    }
}

#if DEBUG || CMUX_BENCH_HOOKS
extension AgentPaneView {
    /// What this pane shows now, for ``ChatOpenTrace``: a hold keeping the content it replaces, its
    /// loading cover, the launch image, or the page before or after its first contentful paint.
    var traceSurface: ChatOpenTrace.Surface {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return .gone }
        if alphaValue == 0 { return .held }
        if loadingView.superview != nil {
            if loadingView.isHidden { return .image }
            return loadingView.isLeaving ? .coverLeaving : .cover
        }
        if pageContent.alphaValue == 0 { return .cover }
        // The page's own first frame (``PagePaintProbe``), the same signal in both engines.
        guard let page else { return model.hasPainted ? .page : .pageEmpty }
        // A spare adopted for this chat (``adoptSession(_:revealTurn:moved:)``) painted its first frame
        // as New Tab, before this trace began: its chat's frame is the pane's paint report.
        return ChatOpenTrace.shared.has(.pagePainted) || (page.hasPainted && model.hasPainted) ? .page : .pageEmpty
    }
}
#endif
