import AppKit
import CmuxNextDesign
import CmuxNextTabs
import Observation

/// One layout leaf: the pane's tab strip on top and the selected tab's
/// content below. Manual frame layout; heights come from live design tokens.
final class PaneContentView: NSView {
    let stripView: TabStripView
    private let contentHost = NSView()
    private(set) weak var content: NSView?
    private var tokenObservation: Task<Void, Never>?
    /// The pane's size changed (divider drag, window resize, animation).
    var onResize: (() -> Void)?

    init(stripModel: TabStripModel) {
        stripView = TabStripView(model: stripModel)
        stripView.dragsWindowFromEmptySpace = false
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        wantsLayer = true
        layer?.backgroundColor = Palette.contentBackground.cgColor
        contentHost.wantsLayer = true
        addSubview(contentHost)
        addSubview(stripView)
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
        guard contentHost.frame != hostFrame else { return }
        contentHost.frame = hostFrame
        onResize?()
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
        content = view
        return previous
    }

    /// Lets the content view go without touching it if another pane took
    /// it.
    func detachContent() {
        if hostsContent { content?.removeFromSuperview() }
        content = nil
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

    func themeDidChange() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.contentBackground.cgColor
        }
    }
}
