import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextLayout
import CmuxNextTabs
import Observation

/// One workspace's content: the layout on top and the screen tab bar along
/// the bottom edge. The bar takes space only while the workspace has two or
/// more screens (`showsBar`); with one screen the layout fills the view.
final class WorkspaceContentView: NSView {
    let layoutView: NSView
    let bar: TabStripView
    private(set) var emptyView: NSView?
    /// The menu of a right-click that no pane or control took: the window's background
    /// (Change Background…, cx-t2x.4).
    var backgroundMenu: (@MainActor () -> NSMenu?)?
    var showsBar = false {
        didSet {
            guard oldValue != showsBar else { return }
            bar.isHidden = !showsBar
            needsLayout = true
        }
    }
    private var tokenObservation: Task<Void, Never>?
    /// Parked in its window (``ParkingContainer``): set with `isHidden` by `WindowRootView`, so it is
    /// redundant while hidden parking is the only parking.
    private(set) var isParkedOffScreen = false

    /// Parks or shows this workspace's subtree. Observers hear it only while the view is not hidden
    /// (``AppKit/NSView/notifyParkingChange()``): hidden parking sets this after hiding and clears it
    /// before showing, so it walks nothing.
    func setParked(_ parked: Bool) {
        guard parked != isParkedOffScreen else { return }
        isParkedOffScreen = parked
        notifyParkingChange()
    }

    /// Showing a hidden parked view shows it (the side-by-side view unhides companions directly).
    override var isHidden: Bool {
        willSet { if !newValue, isHidden, isParkedOffScreen { isParkedOffScreen = false } }
    }

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
            for await _ in ObservationStream({ Metrics.tabStripHeight }) { self?.needsLayout = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            tokenObservation?.cancel()
        }
    }

    nonisolated override var isFlipped: Bool { true }

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

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let backgroundMenu, isBackground(at: event) else { return super.menu(for: event) }
        return backgroundMenu()
    }

    /// Whether the right-click is on the background itself. A view that showed its own menu or
    /// editor and returned nil (a tab strip's + button) passes the click up to here too.
    private func isBackground(at event: NSEvent) -> Bool {
        guard let point = superview?.convert(event.locationInWindow, from: nil), var view = hitTest(point) else { return false }
        let layout = layoutView as? LayoutRootView
        while view !== self {
            guard view === layoutView || view === emptyView || layout?.isBackground(view) == true,
                  let parent = view.superview else { return false }
            view = parent
        }
        return true
    }

    /// A parked workspace (hidden or parked in its window, `WindowRootView.show`) takes no shortcut,
    /// and its subtree is not walked for one.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, !isParkedOffScreen else { return false }
        if let emptyView, emptyView.performKeyEquivalent(with: event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// A parked workspace lists nothing to VoiceOver or the window's hint targets: AppKit unwraps an
    /// ignored (hidden) view into its children, so the subtree is cut here.
    override func accessibilityChildren() -> [Any]? { isHidden || isParkedOffScreen ? [] : super.accessibilityChildren() }

    /// A parked workspace takes no click: AppKit skips a hidden view, not a parked one.
    override func hitTest(_ point: NSPoint) -> NSView? { isParkedOffScreen ? nil : super.hitTest(point) }

    /// Counts window entries (`debug.layout_counters`): a switch to a parked workspace adds none.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DebugLayoutCounters.workspaceWindowEntries &+= 1 }
    }

    override func layout() {
        super.layout()
        let barHeight = showsBar ? TabStripView.preferredHeight : 0
        layoutView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - barHeight))
        bar.frame = NSRect(x: 0, y: bounds.height - barHeight, width: bounds.width, height: barHeight)
    }
}

extension WorkspaceContentView: ParkingContainer {}
