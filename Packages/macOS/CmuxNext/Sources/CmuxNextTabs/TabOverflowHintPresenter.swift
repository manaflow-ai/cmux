import AppKit
import CmuxNextDesign

/// The Shrink-mode hint (`TabOverflowHintView`, cx-kp9b4): shown the first time this strip's unpinned
/// tabs are at their minimum width, at the strip's trailing end; the tabs' viewport gives it room.
/// The strip holds one and calls `update` after each relayout, `layout`, and `hide`.
@MainActor final class TabOverflowHintPresenter {
    private weak var strip: TabStripView?
    /// The hint view, made when first shown.
    private(set) var hint: TabOverflowHintView?

    init(strip: TabStripView) { self.strip = strip }

    /// Room the hint takes at the trailing end: 0 while it is hidden.
    var reserve: CGFloat {
        guard let hint, !hint.isHidden else { return 0 }
        return hint.preferredWidth
    }

    /// The unpinned tabs share no more than the inactive minimum, in Shrink mode with standard tabs.
    var isCrowdedAtMinimum: Bool {
        guard let strip else { return false }
        let result = strip.result, metrics = strip.metrics
        let flexible = result.slots.count(where: { !$0.isPinned && !$0.isGroupChip && !$0.isCollapsed && $0.id != TabStripView.placeholderID })
        return metrics.overflow == .shrink && strip.model.style != .compact && flexible > 1
            && result.standardWidth > 0 && result.standardWidth <= metrics.minInactiveTabWidth
    }

    /// After each relayout: shows the hint the first time the strip is crowded (one strip at a time, in a
    /// strip wide enough for it and some tabs), hides it once the strip is not, and ends it for good if
    /// scrolling tabs were turned on another way while it showed.
    func update() {
        guard let strip else { return }
        let metrics = strip.metrics
        if let hint, !hint.isHidden {
            if metrics.overflow == .scroll {
                answer(usesScrolling: false)
            } else if !isCrowdedAtMinimum || !strip.isShownInWindow {
                hide()
            }
            return
        }
        guard DesignSettings.shared.useScrollingTabs != nil, !TabOverflowHintView.isAnswered,
              TabOverflowHintView.owner == nil || TabOverflowHintView.owner === strip,
              strip.isShownInWindow, strip.drag == nil, isCrowdedAtMinimum else { return }
        let hint = self.hint ?? make(in: strip)
        // A narrow pane keeps its tabs: the hint waits for a crowded strip with room for it, the selected
        // tab and two more at their minimum (an 1100 pt window's 854 pt strip shows it).
        guard strip.bounds.width >= hint.preferredWidth + metrics.minActiveTabWidth + 2 * metrics.minInactiveTabWidth else { return }
        TabOverflowHintView.owner = strip
        hint.isHidden = false
        strip.needsLayout = true
    }

    func hide() {
        guard let hint, !hint.isHidden else { return }
        hint.isHidden = true
        if TabOverflowHintView.owner === strip { TabOverflowHintView.owner = nil }
        strip?.needsLayout = true
    }

    /// Use Scrolling Tabs or the x: never again, on any strip.
    func answer(usesScrolling: Bool) {
        TabOverflowHintView.defaults.set(true, forKey: TabOverflowHintView.answeredKey)
        hide()
        if usesScrolling { DesignSettings.shared.useScrollingTabs?() }
    }

    /// Places the hint after the tabs' viewport (and its +), on the tabs' line.
    func layout() {
        guard let strip, let hint, !hint.isHidden else { return }
        let metrics = strip.metrics
        let width = hint.preferredWidth
        let height = min(metrics.tabHeight, strip.bounds.height)
        hint.frame = CGRect(x: strip.bounds.width - metrics.stripHorizontalPadding - width, y: strip.tabTop, width: width, height: height)
    }

    private func make(in strip: TabStripView) -> TabOverflowHintView {
        let hint = TabOverflowHintView()
        hint.isHidden = true
        hint.onAnswer = { [weak self] usesScrolling in self?.answer(usesScrolling: usesScrolling) }
        strip.contentView.addSubview(hint)
        self.hint = hint
        return hint
    }
}
