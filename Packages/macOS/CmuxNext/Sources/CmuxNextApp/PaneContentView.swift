import AppKit
import CmuxNextDesign
import CmuxNextTabs
import Observation

/// One layout leaf: the pane's tab strip on top (or at the bottom,
/// `tabs.barPosition`, R109) and the selected tab's content beside it.
/// Manual frame layout; heights come from live design tokens.
/// The strip (plus a browser toolbar) is the pane's header, or with the
/// strip at the bottom its footer: the layout's border and rounded corners
/// trace only the content between them.
final class PaneContentView: NSView, PaneContentChrome {
    let stripView: TabStripView
    /// The strip's colors: its pane's scope, subtler while another pane
    /// has focus (`setChromeEmphasis`).
    private let stripScope = ThemeScope(level: .terminal)
    let contentHost = NSView()
    private(set) weak var content: NSView?
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
    /// A browser's tab bar above or below its toolbar (`tabs.barOrder`, R109).
    var barOrder: TabBarOrder = .aboveToolbar {
        didSet { if barOrder != oldValue { updateBand() } }
    }
    /// The browser whose header band the strip uses (`PaneContentView+Band`).
    weak var bandHost: (any PaneHeaderBandHosting)?
    /// The strip's constraints to that band; empty while it is not pinned.
    var bandPins: [NSLayoutConstraint] = []
    /// Whether the strip is pinned to a browser's header band.
    var isBandActive: Bool { !bandPins.isEmpty }
    private var reportedChrome: (header: CGFloat, footer: CGFloat) = (-1, -1)
    /// The outgoing view kept while the shown one has not painted (`PaneContentView+PaintHold`).
    var paintHold: PanePaintHold?
    var paintHoldCounter: UInt64 = 0

    /// - Parameter reveal: Holds the strip until the first tabs arrive and
    ///   the content until the first terminal frame (launch load-in).
    init(stripModel: TabStripModel, reveal: LaunchReveal = .shared) {
        stripView = TabStripView(model: stripModel)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        barPosition = DesignSettings.shared.tabBarPosition
        barOrder = DesignSettings.shared.tabBarOrder
        wantsLayer = true
        contentHost.wantsLayer = true
        contentHost.layer?.masksToBounds = true
        addSubview(contentHost)
        addSubview(stripView)
        stripScope.root(stripView)
        reveal.hold(stripView, until: .tabs)
        reveal.hold(contentHost, until: .pane)
        themeDidChange()
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ PaneChromeMetrics.current }) {
                self?.needsLayout = true
                self?.refreshBandHeight()
            }
        }
        placementObservation = Task { [weak self] in
            for await (position, order) in Observations({ (DesignSettings.shared.tabBarPosition, DesignSettings.shared.tabBarOrder) }) {
                self?.barPosition = position
                self?.barOrder = order
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
        placementObservation?.cancel()
    }


    override var isFlipped: Bool { true }

    override func layout() {
        let stripHeight = self.stripHeight
        let contentHeight = max(0, bounds.height - stripHeight)
        let onTop = barPosition == .top
        // Pinned to a browser's band, the strip follows its constraints and
        // the browser fills the pane (its band holds the strip's place).
        if !isBandActive { stripView.frame = NSRect(x: 0, y: onTop ? 0 : contentHeight, width: bounds.width, height: stripHeight) }
        let hostFrame = isBandActive ? bounds : NSRect(x: 0, y: onTop ? stripHeight : 0, width: bounds.width, height: contentHeight)
        reportHeaderIfChanged()
        let hostChanged = contentHost.frame != hostFrame
        if hostChanged { contentHost.frame = hostFrame }
        // After the host frame: a strip pinned to a browser's band reads its
        // frame from constraints that depend on the host frame.
        super.layout()
        // Restored terminal views are attached while the pane is still at
        // zero size. Reapply their frame after the host receives its launch
        // bounds so Ghostty and its find/glass overlays get a real first
        // layout pass instead of staying at width zero.
        if let content, content.frame != contentHost.bounds { content.frame = contentHost.bounds }
        if hostChanged { onResize?() }
    }

    // MARK: PaneContentChrome

    /// The hosted content's own header (a browser toolbar), if it has one.
    private var innerChrome: PaneContentChrome? { hostsContent ? content as? PaneContentChrome : nil }

    var paneHeaderHeight: CGFloat {
        // The band is inside the browser's header.
        (barPosition == .top && !isBandActive ? stripHeight : 0) + (innerChrome?.paneHeaderHeight ?? 0)
    }

    /// The strip below the content (`tabs.barPosition` bottom); else 0.
    var paneFooterHeight: CGFloat { barPosition == .bottom ? stripHeight : 0 }

    /// The strip's height: its tabs sit with equal gaps above (from the
    /// pane cell's top, through the pane padding) and below (to the content
    /// border), on this window's pixel grid (`PaneChromeMetrics`).
    var stripHeight: CGFloat {
        PaneChromeMetrics.current.resolvedStripHeight(scale: window?.backingScaleFactor ?? 2)
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

    /// A browser rounds its page area below its toolbar; a terminal is
    /// rounded here, by the content host.
    private func applyCornerRadius() {
        let hostRadius: CGFloat
        if let innerChrome {
            innerChrome.setPaneContentCornerRadius(contentCornerRadius)
            hostRadius = 0
        } else {
            hostRadius = contentCornerRadius
        }
        guard let layer = contentHost.layer, layer.cornerRadius != hostRadius else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.cornerRadius = hostRadius
        CATransaction.commit()
    }

    func paneFrameInWindowDidChange() {
        stripView.updateWindowControlsAvoidance()
        // The pane moved under a possibly still pointer (column scroll, split resize).
        stripView.paneMovedInWindow()
    }

    private func reportHeaderIfChanged() {
        let chrome = (header: paneHeaderHeight, footer: paneFooterHeight)
        guard chrome != reportedChrome else { return }
        reportedChrome = chrome
        onPaneHeaderHeightChange?()
    }

    /// Swaps the hosted content view. Returns the previous one. Focus is
    /// not handled here: the window's `FocusCoordinator` re-targets the
    /// keyboard when the pane reports the new content.
    @discardableResult
    func show(_ view: NSView?) -> NSView? {
        let previous = content
        guard previous !== view || (view != nil && !hostsContent) else { return previous }
        // Another pane may have reparented `previous` already (a moved tab):
        // only a view still installed here is removed.
        let hosted = previous.flatMap { $0.superview === contentHost ? $0 : nil }
        // An agent page draws nothing until it paints: what this pane showed
        // stays until then (`beginPaintHold`), not an empty pane. Not a
        // browser whose header band the strip leaves now (its header would
        // jump while it stays).
        let holds = !isBandActive && holdsForFirstPaint(view, replacing: hosted)
        // The strip's band pins end before the browser leaves (R109).
        if hosted !== view { releaseBand() }
        // An earlier switch still waiting on a first frame ends now.
        endPaintHold()
        if hosted !== view, !holds { hosted?.removeFromSuperview() }
        if let view, view.superview !== contentHost || view.frame != contentHost.bounds {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
        }
        if holds, let hosted, let view { beginPaintHold(outgoing: hosted, incoming: view) }
        // A terminal's theme scope inherits this pane's workspace theme.
        view?.reparentRootedThemeScope()
        // Another pane may own `previous` now and have taken its callback.
        if let previous, previous !== view, previous.superview == nil {
            (previous as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }
        content = view
        if let inner = innerChrome {
            // A toolbar or bookmarks bar height change moves the strip and
            // the content: lay out again, then report (v4 review b).
            inner.onPaneHeaderHeightChange = { [weak self] in
                self?.needsLayout = true
                self?.reportHeaderIfChanged()
            }
        }
        applyCornerRadius()
        updateBand()
        reportHeaderIfChanged()
        return previous
    }

    /// Lets the content view go without touching it if another pane took
    /// it.
    func detachContent() {
        // The strip's band pins end before the browser leaves (R109).
        releaseBand()
        endPaintHold()
        if hostsContent {
            (content as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
            content?.removeFromSuperview()
        }
        content = nil
        applyCornerRadius()
        updateBand()
        reportHeaderIfChanged()
    }

    /// `content` is installed in this pane (another pane may have taken it).
    var hostsContent: Bool {
        guard let content else { return false }
        return content.superview === contentHost
    }

    func setChromeEmphasis(_ emphasis: ChromeEmphasis, animated: Bool) {
        stripScope.setEmphasis(emphasis, animated: animated)
    }

    /// The strip's scope follows the pane's (a workspace theme).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The pins need both views in one window (v4 note 1).
        updateBand()
        stripView.reparentRootedThemeScope()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
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
        let paints = WindowBackdrop(tokens).panesPaintBackground
        performWithTheme {
            contentHost.layer?.backgroundColor = paints ? Palette.surfaceBackground.cgColor : nil
        }
        // The strip: clear, or the user's tab bar background (R55).
        stripView.wantsLayer = true
        stripView.layer?.backgroundColor = stripView.performWithTheme { Palette.surfaceOverride(.tabBar)?.cgColor }
    }
}

// A terminal or page edge inside the titlebar band never moves the window;
// the strip, hit before this view, answers for its own empty space.
extension PaneContentView: TitlebarPressDeciding {
    func titlebarPress(atWindowPoint windowPoint: CGPoint) -> TitlebarPress { .staysPut }
}
