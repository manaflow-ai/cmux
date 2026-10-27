public import AppKit
import CmuxNextDesign
public import CmuxNextInput
public import CmuxNextWakeups

// Whether the strip is in sight, and what follows from it (split from TabStripView.swift): the window fan-outs, the
// pointer state a hidden strip gets no exit for, and the appearance a hidden strip applies when it shows.
extension TabStripView {
    /// A strip with a deadline placer of its own on a main-thread scheduler of its own, under an always-visible node
    /// (tests and the demo; the App passes its one placer and the pane's or bar's node).
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

    // visibility-walk-allow: input state on hide: the strip leaves the window's fan-outs and ends its pointer state (a hidden strip gets no exit event)
    public override func viewDidHide() {
        super.viewDidHide()
        syncShown(false)
    }

    // visibility-walk-allow: input state on unhide: the strip joins the window's fan-outs again and lands what changed while hidden, once
    public override func viewDidUnhide() {
        super.viewDidUnhide()
        syncShown()
    }

    /// The window-wide fan-outs (hover-card hit tests, main and occlusion changes) reach only a
    /// shown strip: a hidden one (a parked workspace, still in its window, or a hidden screen bar)
    /// is not in them, and an appearance or scale change waits until it shows. Showing re-reads
    /// the window's state and applies, without motion, the model changes that came while hidden
    /// (``syncFromModel()`` lays nothing out out of sight). ``isShownInWindow`` keeps the answer, so
    /// the strip's hit tests and key intercepts read it instead of walking its ancestors.
    func syncShown(_ shown: Bool? = nil) {
        // visibility-walk-allow: one walk per window move, hide or unhide: the strip copies AppKit's hidden state into isShownInWindow (no node holds a view's isHidden)
        let shown = shown ?? (window != nil && !isHiddenOrHasHiddenAncestor)
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
        // What changed while out of sight lands at once in its final place: nobody saw it move.
        if modelChangedWhileHidden {
            modelChangedWhileHidden = false
            sync(fromModel: true, animating: false)
        }
        hoverCards.register(hoverCard)
        applyMultiSelection()
        if appearanceIsStale {
            appearanceIsStale = false
            applyAppearance()
            applyFrames()
        }
    }

    // visibility-walk-allow: a hidden strip defers it already (appearanceIsStale, applied once in syncShown's show); a shown one sets its layers' theme scope and scale
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard isShownInWindow || window == nil else {
            appearanceIsStale = true
            return
        }
        applyAppearance()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard isShownInWindow || window == nil else {
            appearanceIsStale = true
            return
        }
        applyAppearance()
        applyFrames()
    }

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
