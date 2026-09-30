import AppKit
import CmuxNextDesign
import CmuxNextTabs
import Observation

/// One layout leaf: the pane's tab strip on top and the selected tab's
/// content below. Manual frame layout; heights come from live design tokens.
/// The strip (plus a browser toolbar) is the pane's header: the layout's
/// border and rounded corners trace only the content below it.
final class PaneContentView: NSView, PaneContentChrome {
    let stripView: TabStripView
    private let contentHost = NSView()
    private(set) weak var content: NSView?
    private var tokenObservation: Task<Void, Never>?
    /// The pane's size changed (divider drag, window resize, animation).
    var onResize: (() -> Void)?
    var onPaneHeaderHeightChange: (() -> Void)?
    private var contentCornerRadius: CGFloat = 0
    private var reportedHeader: CGFloat = -1

    init(stripModel: TabStripModel) {
        stripView = TabStripView(model: stripModel)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        contentHost.wantsLayer = true
        contentHost.layer?.masksToBounds = true
        addSubview(contentHost)
        addSubview(stripView)
        themeDidChange()
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ Metrics.tabStripHeight }) { self?.needsLayout = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let stripHeight = Metrics.tabStripHeight
        stripView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        let hostFrame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: max(0, bounds.height - stripHeight))
        reportHeaderIfChanged()
        guard contentHost.frame != hostFrame else { return }
        contentHost.frame = hostFrame
        onResize?()
    }

    // MARK: PaneContentChrome

    /// The hosted content's own header (a browser toolbar), if it has one.
    private var innerChrome: PaneContentChrome? { hostsContent ? content as? PaneContentChrome : nil }

    var paneHeaderHeight: CGFloat { Metrics.tabStripHeight + (innerChrome?.paneHeaderHeight ?? 0) }

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
    }

    private func reportHeaderIfChanged() {
        let header = paneHeaderHeight
        guard header != reportedHeader else { return }
        reportedHeader = header
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
        if hosted !== view { hosted?.removeFromSuperview() }
        if let view, view.superview !== contentHost || view.frame != contentHost.bounds {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
        }
        // A terminal's theme scope inherits this pane's workspace theme.
        view?.reparentRootedThemeScope()
        // Another pane may own `previous` now and have taken its callback.
        if let previous, previous !== view, previous.superview == nil {
            (previous as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
        }
        content = view
        if let inner = innerChrome {
            inner.onPaneHeaderHeightChange = { [weak self] in self?.reportHeaderIfChanged() }
        }
        applyCornerRadius()
        reportHeaderIfChanged()
        return previous
    }

    /// Lets the content view go without touching it if another pane took
    /// it.
    func detachContent() {
        if hostsContent {
            (content as? PaneContentChrome)?.onPaneHeaderHeightChange = nil
            content?.removeFromSuperview()
        }
        content = nil
        applyCornerRadius()
        reportHeaderIfChanged()
    }

    /// `content` is installed in this pane (another pane may have taken it).
    var hostsContent: Bool {
        guard let content else { return false }
        return content.superview === contentHost
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        themeDidChange()
    }

    /// The content background, or nothing in a translucent window, where
    /// the window root paints the one sheet (`WindowBackdrop`).
    func themeDidChange() {
        let tokens = themeTokens
        let paints = WindowBackdrop(backgroundOpacity: tokens.backgroundOpacity, backgroundBlur: tokens.backgroundBlur).panesPaintBackground
        performWithTheme {
            layer?.backgroundColor = paints ? Palette.contentBackground.cgColor : nil
        }
    }
}
