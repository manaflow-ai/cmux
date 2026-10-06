import AppKit
import CmuxNextDesign
import CmuxNextTabs
import Observation

/// One workspace's content: the layout on top and the screen tab bar along
/// the bottom edge. The bar takes space only while the workspace has two or
/// more screens (`showsBar`); with one screen the layout fills the view.
final class WorkspaceContentView: NSView {
    let layoutView: NSView
    let bar: TabStripView
    private(set) var emptyView: NSView?
    var showsBar = false {
        didSet {
            guard oldValue != showsBar else { return }
            bar.isHidden = !showsBar
            needsLayout = true
        }
    }
    private var tokenObservation: Task<Void, Never>?

    init(layoutView: NSView, bar: TabStripView) {
        self.layoutView = layoutView
        self.bar = bar
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        wantsLayer = true
        layoutView.autoresizingMask = []
        addSubview(layoutView)
        bar.isHidden = true
        addSubview(bar)
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

    /// Shows the workspace action surface in place of an empty layout.
    func showEmpty(_ view: NSView?) {
        guard emptyView !== view else { return }
        emptyView?.removeFromSuperview()
        emptyView = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view, positioned: .above, relativeTo: nil)
            view.reparentRootedThemeScope()
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            layoutView.isHidden = true
            bar.isHidden = true
        } else {
            layoutView.isHidden = false
            bar.isHidden = !showsBar
        }
    }

    override func layout() {
        super.layout()
        let barHeight = showsBar ? TabStripView.preferredHeight : 0
        layoutView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        bar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
    }
}
