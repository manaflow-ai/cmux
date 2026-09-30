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
        contentHost.frame = NSRect(x: 0, y: stripHeight, width: bounds.width, height: max(0, bounds.height - stripHeight))
    }

    /// Swaps the hosted content view. Returns the previous one. Focus is
    /// not handled here: the window's `FocusCoordinator` re-targets the
    /// keyboard when the pane reports the new content.
    @discardableResult
    func show(_ view: NSView?) -> NSView? {
        let previous = content
        guard previous !== view else { return previous }
        previous?.removeFromSuperview()
        if let view {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            contentHost.addSubview(view)
        }
        content = view
        return previous
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Palette.contentBackground.cgColor
        }
    }
}
