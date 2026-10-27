import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextTabs
import CmuxNextWakeups
import Observation
import os

/// One layout leaf: the pane's tab strip on top (or at the bottom,
/// `tabs.barPosition`, R109) and the selected tab's content beside it.
/// Manual frame layout; heights come from live design tokens.
/// The strip is the pane's header, or with the strip at the bottom its
/// footer: the layout's border and rounded corners trace the content host
/// between them, a browser's toolbar included.
final class PaneContentView: NSView, PaneContentChrome {
    let stripView: TabStripView
    /// The strip's colors: its pane's scope, subtler while another pane
    /// has focus (`setChromeEmphasis`).
    private let stripScope = ThemeScope(level: .terminal)
    /// The pane's own scope, under its workspace's: it pins nothing unless the pane has its own
    /// background (`PaneContentView+Backdrop`), so its strip and content inherit as before.
    let paneScope = ThemeScope(level: .workspace)
    /// The pane's own background and tint (`PaneContentView+Backdrop`).
    let backdropState = PaneBackdropState()
    private var paneBackgroundsObservation: Task<Void, Never>?
    let contentHost = NSView()
    private(set) weak var content: NSView?
    /// A view in the window that this pane, in no window yet, shows: it moves here when the pane enters one.
    private var windowEntry = WindowEntryHandoff()
    private var tokenObservation: Task<Void, Never>?
    /// The pane's size changed (divider drag, window resize, animation).
    var onResize: (() -> Void)?
    var onPaneHeaderHeightChange: (() -> Void)?
    private var contentCornerRadius: CGFloat = 0
    /// The edge the strip sits on (`tabs.barPosition`, R109); follows
    /// `DesignSettings` (`observePlacement`).
    var barPosition: TabBarPosition = .top {
        didSet { if barPosition != oldValue { updateBand() } }
    }
    private var placementObservation: Task<Void, Never>?
    /// The pane's buttons at the strip's trailing end (`PaneContentView+Toolbar`).
    var toolbar: PaneToolbar? { didSet { installToolbar(replacing: oldValue) } }
    /// Its tab bar's empty space drags the pane onto another to swap them (cx-8bv1j).
    var swapDrag: PaneSwapDrag?
    /// The acting agent's name tag (`PaneContentView+AgentTag`).
    let agentTag = AgentPresenceTagView()
    private var agentTagObservation: Task<Void, Never>?
    /// No strip: the person hid this pane's tab bar (``PaneTabBar``).
    var hidesStrip = false {
        didSet {
            guard hidesStrip != oldValue else { return }
            // Applied in layout(): a paint hold may keep the strip until its swap.
            refreshBandHeight()
            needsLayout = true
        }
    }
    /// A browser's tab bar above or below its toolbar (`tabs.barOrder`, R109).
    var barOrder: TabBarOrder = .aboveToolbar {
        didSet { if barOrder != oldValue { updateBand() } }
    }
    /// The edge a browser's or page's omnibar row sits on (`browser.toolbarPosition`); the
    /// pane hands it to what it shows. Follows `DesignSettings` (`observePlacement`).
    var toolbarPosition: ToolbarPosition = .top {
        didSet {
            guard toolbarPosition != oldValue else { return }
            // Pinned to the same browser, the pins and VoiceOver order are made again for the new edge.
            releaseBand()
            applyToolbarPosition()
            updateBand()
        }
    }
    /// The browser whose header band the strip uses (`PaneContentView+Band`).
    weak var bandHost: (any PaneHeaderBandHosting)?
    /// The strip's constraints to that band; empty while it is not pinned.
    var bandPins: [NSLayoutConstraint] = []
    /// Whether the strip is pinned to a browser's header band.
    var isBandActive: Bool { !bandPins.isEmpty }
    private var reportedChrome: (header: CGFloat, footer: CGFloat, framed: Bool) = (-1, -1, true)
    /// The outgoing view kept while the shown one has not painted (`PaneContentView+PaintHold`).
    let paintHold = PanePaintHold(owner: "pane.paint-hold")
    /// The strip the hold's outgoing view showed under, kept until the swap.
    var holdKeepsStrip = false
    /// An agent page's last image under the content at launch (`PaneContentView+LaunchImage`).
    var launchImageView: NSView?
    /// Runs once when the launch image goes (`clearLaunchImage`).
    var onLaunchImageCleared: (() -> Void)?
    /// Asked when the launch image's limit is up, before it goes: `false` keeps the frame, because
    /// the page it stands in for is still coming and dropping it now would leave the pane empty
    /// (`PaneContentView+LaunchImage`). Nil means the limit clears it, as it does for a frame held
    /// over a page that has already painted.
    var launchImageMayClear: (() -> Bool)?
    let launchImageDeadline = DemandTimer(owner: "pane.launch-image")
    /// Browsers this pane showed before, kept in place and hidden, oldest
    /// first (`PaneContentView+Parking`).
    var parked: [ParkedContent] = []

    /// - Parameter reveal: Holds the strip until the first tabs arrive and
    ///   the content until the first terminal frame (launch load-in).
    init(stripModel: TabStripModel, reveal: LaunchReveal = .shared) {
        stripView = TabStripView(model: stripModel)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        barPosition = DesignSettings.shared.tabBarPosition
        barOrder = DesignSettings.shared.tabBarOrder
        toolbarPosition = DesignSettings.shared.browserToolbarPosition
        wantsLayer = true
        contentHost.wantsLayer = true
        contentHost.layer?.masksToBounds = true
        addSubview(contentHost)
        addSubview(stripView)
        paneScope.root(self)
        stripScope.root(stripView)
        reveal.hold(stripView, until: .tabs)
        reveal.hold(contentHost, until: .pane)
        agentTagObservation = observeAgentTag(stripModel)
        themeDidChange()
        tokenObservation = Task { [weak self] in
            for await _ in ObservationStream({ (PaneChromeMetrics.current, ChromeTunables.tabRowTools.value) }) {
                self?.needsLayout = true
                self?.refreshBandHeight()
            }
        }
        paneBackgroundsObservation = Task { [weak self] in
            for await _ in ObservationStream({ DesignSettings.shared.paneBackgrounds }) { self?.paintPaneBackdrop() }
        }
        placementObservation = Task { [weak self] in
            for await (position, order, toolbar) in ObservationStream({
                (DesignSettings.shared.tabBarPosition, DesignSettings.shared.tabBarOrder, DesignSettings.shared.browserToolbarPosition)
            }) {
                self?.barPosition = position
                self?.barOrder = order
                self?.toolbarPosition = toolbar
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            tokenObservation?.cancel()
            placementObservation?.cancel()
            paneBackgroundsObservation?.cancel()
            agentTagObservation?.cancel()
        }
    }


    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        let stripHeight = self.stripHeight
        let contentHeight = max(0, bounds.height - stripHeight)
        let onTop = barPosition == .top
        // Pinned to a browser's band, the strip follows its constraints and
        // the browser fills the pane (its band holds the strip's place).
        let shown = shownStripHeight
        stripView.isHidden = shown <= 0
        toolbar?.view.isHidden = shown <= 0
        let tools = toolbarWidth(shown: shown), room = bounds.width - tools, row = onTop && !isBandActive && !hidesStrip && hostsContent && shown > 0 ? content as? PaneTabRowSharing : nil
        let rowContent = row?.fitsTabRow(room: room) == true ? row : nil, rowTools = rowContent?.tabRowWidth(room: room) ?? 0 // a chat's tools in the row when they fit (PaneTabRowSharing)
        if !isBandActive {
            stripView.frame = NSRect(x: 0, y: onTop ? 0 : bounds.height - shown, width: bounds.width - tools - rowTools, height: shown)
            toolbar?.view.frame = NSRect(x: bounds.width - tools, y: stripView.frame.minY, width: tools, height: shown)
        }
        let hostFrame = isBandActive || rowTools > 0 ? bounds : NSRect(x: 0, y: onTop ? stripHeight : 0, width: bounds.width, height: contentHeight)
        reportHeaderIfChanged()
        let hostChanged = contentHost.frame != hostFrame
        if hostChanged { contentHost.frame = hostFrame }
        // After the host frame: a strip pinned to a browser's band reads its
        // frame from constraints that depend on the host frame.
        super.layout()
        toolbar?.view.refreshCorner() // "…"'s hover spans the strip's frame, set above or by the band's constraints
        // Restored terminal views are attached while the pane is still at
        // zero size. Reapply their frame after the host receives its launch
        // bounds so Ghostty and its find/glass overlays get a real first
        // layout pass instead of staying at width zero.
        if hostsContent, let content {
            let resized = content.frame != contentHost.bounds
            if resized { content.frame = contentHost.bounds }
            // Content shown before the pane had its size (a restored selected
            // tab) was laid out at that size. A browser chrome lays out its
            // toolbar and page area by constraints from its own bounds: left
            // to AppKit's follow-up pass it can keep the stale frames (page
            // area 0 high at the bottom, toolbar under it) until a tab switch.
            // Lay it out at its new size now, in this pass (a descendant).
            if hostChanged || resized {
                content.needsLayout = true
                content.layoutSubtreeIfNeeded()
            }
        }
        // A chat shown at the frame it was parked at (`install`) follows the host again.
        if hostsContent, let content, content.autoresizingMask.isEmpty, content is PaneParkableContent {
            content.autoresizingMask = [.width, .height]
        }
        layoutParked()
        layoutAgentTag()
        if hostsContent, let sharing = content as? PaneTabRowSharing { sharing.offerTabRow(height: rowContent == nil ? 0 : shown, trailingInset: tools, in: self) }
        if hostChanged { onResize?() }
    }

    // MARK: PaneContentChrome

    private var visibleContent: NSView? {
        paintHold.kept.flatMap { $0.superview === contentHost ? $0 : nil } ?? (hostsContent ? content : nil)
    }

    var paneFramesContent: Bool { !(visibleContent is AgentPaneView) }

    /// The hosted content's own header, if it reports one (a browser's
    /// toolbar does not: it is inside the content area).
    private var innerChrome: PaneContentChrome? { visibleContent as? PaneContentChrome }

    /// A chat with its native tab strip hidden still owns the top strip in its
    /// webview. Keep the pane ring below that strip so focus does not draw an
    /// extra hairline above the chat header (Austin, 2026-10-23).
    private var hiddenAgentHeaderHeight: CGFloat {
        guard hidesStrip, visibleContent is AgentPaneView else { return 0 }
        return PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
    }

    var paneHeaderHeight: CGFloat {
        if hiddenAgentHeaderHeight > 0 { return hiddenAgentHeaderHeight }
        // The band is inside the browser, under its toolbar.
        return (barPosition == .top && !isBandActive ? shownStripHeight : 0) + (innerChrome?.paneHeaderHeight ?? 0)
    }

    /// The strip below the content (`tabs.barPosition` bottom); else 0. In a browser's band
    /// (between its page and a bottom toolbar) it is inside the content area.
    var paneFooterHeight: CGFloat { barPosition == .bottom && !isBandActive ? shownStripHeight : 0 }

    /// The strip's height: its tabs sit with equal gaps above (from the
    /// pane cell's top, through the pane padding) and below (to the content
    /// border), on this window's pixel grid (`PaneChromeMetrics`).
    var stripHeight: CGFloat {
        hidesStrip ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshBandHeight()
        needsLayout = true
    }

    func setPaneContentCornerRadius(_ radius: CGFloat) {
        contentCornerRadius = radius
        applyCornerRadius()
    }

    /// The content host is the pane's one rounded container, for every kind
    /// of content: a browser's toolbar sits inside it, as a terminal does.
    private func applyCornerRadius() {
        let radius = paneFramesContent ? contentCornerRadius : 0
        guard let layer = contentHost.layer, layer.cornerRadius != radius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = radius
        CATransaction.commit()
    }

    func paneFrameInWindowDidChange() {
        stripView.updateWindowControlsAvoidance()
        // Content with no strip of its own over it (Home's header) keeps clear of the traffic lights too.
        if let window = window as? ShellWindow { window.windowControlsAvoiders.update(in: window) }
        // The pane moved under a possibly still pointer (column scroll, split resize).
        stripView.paneMovedInWindow()
    }

    private func reportHeaderIfChanged() {
        let chrome = (header: paneHeaderHeight, footer: paneFooterHeight, framed: paneFramesContent)
        guard chrome != reportedChrome else { return }
        reportedChrome = chrome
        onPaneHeaderHeightChange?()
    }

    /// A first-paint hold ended: framing follows the view that became visible in this transaction.
    func refreshContentFrame() {
        applyCornerRadius()
        reportHeaderIfChanged()
    }

    /// Swaps the hosted content view. Returns the previous one. Focus is
    /// not handled here: the window's `FocusCoordinator` re-targets the
    /// keyboard when the pane reports the new content.
    @discardableResult
    func show(_ view: NSView?) -> NSView? {
        let previous = content
        guard previous !== view || (view != nil && !hostsContent) else { return previous }
        tabSwitchMark("show")
        defer { tabSwitchMark("shown") }
        // Another pane may have reparented `previous` already (a moved tab):
        // only a view still installed here is removed.
        let hosted = previous.flatMap { $0.superview === contentHost ? $0 : nil }
        // An agent page draws nothing until it paints: what this pane showed
        // stays until then (`beginPaintHold`), not an empty pane. Not a
        // browser whose header band the strip leaves now (its header would
        // jump while it stays). While an earlier switch waits, what shows is
        // the content it keeps.
        let kept = paintHold.kept.flatMap { $0.superview === contentHost ? $0 : nil }
        let shown = kept ?? hosted
        let holds = !isBandActive && holdsForFirstPaint(view, replacing: shown)
        // The strip's band pins end before the browser leaves (R109).
        if hosted !== view { releaseBand() }
        if holds, kept != nil {
            // The page that never showed leaves; what shows stays for this hold.
            paintHold.handOff { [weak self] page in self?.retire(page) }
        } else {
            // An earlier switch still waiting on a first frame ends now.
            endPaintHold()
        }
        let leaving = hosted !== view && !holds ? hosted : nil
        // Its omnibar row on this pane's edge before it lays out here.
        (view as? any ToolbarEdgeHosting)?.toolbarPosition = toolbarPosition
        if let view, !windowEntry.defers(view, to: contentHost) { install(view, replacing: leaving) }
        if holds, let shown, let view { beginPaintHold(outgoing: shown, incoming: view) }
        // A terminal's theme scope inherits this pane's workspace theme.
        view?.reparentRootedThemeScope()
        // Another pane may own `previous` now and have taken its callback.
        if let previous, previous !== view, previous.superview == nil { (previous as? PaneContentChrome)?.onPaneHeaderHeightChange = nil }
        content = view
        // After the incoming view is in: a browser that leaves stays parked
        // here, and the keyboard it held goes to what shows now.
        if let leaving { retire(leaving) }
        if let inner = innerChrome {
            // A toolbar or bookmarks bar height change only reshapes the
            // pane's rounded area and ring. It arrives from the browser
            // chrome's own layout(): this pane's frames do not depend on it
            // (a pinned strip follows its band constraints), so no layout of
            // this ancestor is requested from inside that pass.
            inner.onPaneHeaderHeightChange = { [weak self] in
                guard let self else { return }
                self.reportHeaderIfChanged()
                // A strip pinned to the browser's band follows the band's
                // guide: one more layout of this pane, asked for after the
                // window's pass, never from inside the browser's layout.
                guard self.isBandActive else { return }
                if let window = self.window as? ShellWindow {
                    window.afterLayoutPass { [weak self] in self?.needsLayout = true }
                } else {
                    self.needsLayout = true
                }
            }
        }
        applyCornerRadius()
        updateBand()
        reportHeaderIfChanged()
        return previous
    }

    /// Lets the content view go without touching it if another pane took it. `parks` (a first
    /// visit, whose surface comes next frame): it stays here, hidden (`retire`), not out of the window.
    func detachContent(parks: Bool = false) {
        // The strip's band pins end before the browser leaves (R109).
        releaseBand()
        // A displaced or closed page cannot reveal this pane's saved frame anymore.
        clearLaunchImage()
        endPaintHold()
        let shown = hostsContent ? content : nil
        (shown as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        content = nil
        if let shown { if parks { retire(shown) } else { shown.removeFromSuperview() } }
        applyCornerRadius()
        updateBand()
        reportHeaderIfChanged()
    }

    /// `content` is installed in this pane (another pane may have taken it).
    var hostsContent: Bool { content?.superview === contentHost }

    func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool) {
        stripScope.setEmphasis(emphasis, animated: animated)
    }

    /// The strip's scope follows the pane's (a workspace theme).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Cmd-N's panes are built outside the window: the New Tab page moves in now, never out of the window.
        if let view = windowEntry.entered(contentHost), view === content { show(view) }
        // The pins need both views in one window (v4 note 1).
        updateBand()
        reparentRootedThemeScope()
        stripView.reparentRootedThemeScope()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        reparentRootedThemeScope()
        stripView.reparentRootedThemeScope()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    /// The content background under the content only (the strip has its
    /// own backdrop), or nothing in a translucent window, where the window
    /// root paints the one sheet (`WindowBackdrop`).
    func themeDidChange() {
        needsLayout = true
        let tokens = themeTokens
        let paints = WindowBackdrop.current(tokens).panesPaintBackground
        performWithTheme {
            contentHost.layer?.backgroundColor = paints ? Palette.surfaceBackground.cgColor : nil
        }
        // The strip: clear, or the user's tab bar background (R55).
        stripView.wantsLayer = true
        stripView.layer?.backgroundColor = stripView.performWithTheme { Palette.surfaceOverride(.tabBar)?.cgColor }
        paintPaneBackdrop()
    }
}

// A terminal or page edge inside the titlebar band never moves the window;
// the strip, hit before this view, answers for its own empty space.
extension PaneContentView: TitlebarPressDeciding {
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }
}

/// Tab switch timeline marks (cx-asb1): wall-clock ms, so a bench can line
/// them up with the page's own clock. Debug level: nothing is written unless
/// a `log stream --level debug` reads category "tab-switch".
private let tabSwitchLog = Logger(subsystem: "com.cmuxterm.app.next", category: "tab-switch")
private func tabSwitchMark(_ name: String) {
    tabSwitchLog.debug("tab-switch \(name, privacy: .public) \(Date().timeIntervalSince1970 * 1_000, format: .fixed(precision: 3), privacy: .public)")
}
