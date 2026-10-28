public import AppKit
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups

// Whether the strip is in sight, and what follows from it (split from TabStripView.swift): the window fan-outs, the
// pointer state a hidden strip gets no exit for, and the work a hidden strip defers on its node until it shows.
extension TabStripView {
    /// A strip with a deadline placer of its own on a main-thread scheduler of its own, under an always-visible root
    /// (tests; the App passes its one placer and the pane's or bar's node).
    public convenience init(model: TabStripModel, background: Background = .none, input: InputEventTap) {
        self.init(model: model, background: background, input: input,
                  deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())),
                  visibilityNode: VisibilityNode(root: "tab-strip", own: .visible))
    }

    /// The strip leaves sight (its window, or hidden in it): its editor panel and pointer
    /// state end, since it gets no exit while hidden. Closing mode belongs to this window's
    /// pointer; the strip shown again lays out fully.
    func endPointerState() {
        groupEditor.hide()
        chipHold.cancel()
        escapeMonitor.remove()
        selectionEscape.remove()
        closingWatch.end()
        closingModeWidth = nil
        menuTracking.end()
        buttonReveal.pointerInStrip = false
    }

    /// Recipe R-hide: AppKit's hide only tells the strip's node; ``syncShown(_:)`` follows the node's flips.
    public override func viewDidHide() {
        super.viewDidHide()
        visibilityNode.set(.hidden)
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        visibilityNode.set(.visible)
    }

    /// The window-wide fan-outs (hover-card hit tests, main and occlusion changes) reach only a strip
    /// in a window whose node is visible: a parked workspace's, a suspended pane's, a hidden screen bar
    /// and a covered or minimized window's strip are not in them, and their spinners stop. The node's
    /// flip to visible re-reads the window's state here, then runs what waited on the node: the model
    /// changes, without motion (``syncFromModel()``), and the appearance. ``isShownInWindow`` keeps the
    /// answer, so the strip's hit tests and key intercepts read it instead of walking its ancestors.
    func syncShown(_ shown: Bool? = nil) {
        let shown = shown ?? (window != nil && visibilityNode.isVisible)
        guard shown != isShownInWindow else { return }
        isShownInWindow = shown
        hoverCards.unregister(hoverCard)
        windowMain.observe(shown ? window : nil) { [weak self] isMain in self?.cells.values.forEach { $0.isWindowMain = isMain } }
        windowVisibility.observe(shown ? window : nil) { [weak self] visible in self?.cells.values.forEach { $0.isWindowVisible = visible } }
        for cell in cells.values { cell.isStripShown = shown }
        guard shown else {
            if window != nil { endPointerState() }
            return
        }
        hoverCards.register(hoverCard)
        applyMultiSelection()
    }

    /// R-appear: a strip out of sight re-themes its layers once, when it shows.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferAppearance(owner: "TabStripView") { [weak self] in self?.applyAppearance() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        visibilityNode.deferUntilVisible(key: Self.backingKey) { [weak self] in
            self?.applyAppearance()
            self?.applyFrames()
        }
    }

    /// The ``visibilityNode`` keys of the strip's deferred work.
    static let backingKey = "TabStripView.backing"
    static let modelSyncKey = "TabStripView.modelSync"

    /// Layers do not inherit theme scope or scale; push both (re-applies colors).
    func applyAppearance() {
        let scope = themeScope
        let scale = window?.backingScaleFactor ?? 2
        for cell in cells.values {
            cell.themeScope = scope
            cell.scale = scale
        }
        for chip in groups.chips.values {
            chip.themeScope = scope
            chip.scale = scale
        }
        for band in groups.bands.values { band.themeScope = scope }
    }
}
