import AppKit
import CmuxNextDesign

/// The Shrink-mode hint (`TabOverflowHintView`, cx-kp9b4): shown the first time this strip's unpinned
/// tabs are at their minimum width, at the strip's trailing end; the tabs' viewport gives it room.
extension TabStripView {
    /// Room the hint takes at the trailing end: 0 while it is hidden.
    var overflowHintReserve: CGFloat {
        guard let hint = overflowHint, !hint.isHidden else { return 0 }
        return hint.preferredWidth
    }

    /// The unpinned tabs share no more than the inactive minimum, in Shrink mode with standard tabs.
    var isCrowdedAtMinimum: Bool {
        let flexible = result.slots.count(where: { !$0.isPinned && !$0.isGroupChip && !$0.isCollapsed && $0.id != Self.placeholderID })
        return metrics.overflow == .shrink && model.style != .compact && flexible > 1
            && result.standardWidth > 0 && result.standardWidth <= metrics.minInactiveTabWidth
    }

    /// After each relayout: shows the hint the first time the strip is crowded (one strip at a time, in a
    /// strip wide enough for it and some tabs), hides it once the strip is not, and ends it for good if
    /// scrolling tabs were turned on another way while it showed.
    func updateOverflowHint() {
        if let hint = overflowHint, !hint.isHidden {
            if metrics.overflow == .scroll {
                answerOverflowHint(usesScrolling: false)
            } else if !isCrowdedAtMinimum || window == nil {
                hideOverflowHint()
            }
            return
        }
        guard DesignSettings.shared.useScrollingTabs != nil, !TabOverflowHintView.isAnswered,
              TabOverflowHintView.owner == nil || TabOverflowHintView.owner === self,
              window != nil, drag == nil, isCrowdedAtMinimum else { return }
        let hint = overflowHint ?? makeOverflowHint()
        // A narrow pane keeps its tabs: the hint waits for a crowded strip with room for it, the selected
        // tab and two more at their minimum (an 1100 pt window's 854 pt strip shows it).
        guard bounds.width >= hint.preferredWidth + metrics.minActiveTabWidth + 2 * metrics.minInactiveTabWidth else { return }
        TabOverflowHintView.owner = self
        hint.isHidden = false
        needsLayout = true
    }

    func hideOverflowHint() {
        guard let hint = overflowHint, !hint.isHidden else { return }
        hint.isHidden = true
        if TabOverflowHintView.owner === self { TabOverflowHintView.owner = nil }
        needsLayout = true
    }

    /// Use Scrolling Tabs or the x: never again, on any strip.
    func answerOverflowHint(usesScrolling: Bool) {
        TabOverflowHintView.defaults.set(true, forKey: TabOverflowHintView.answeredKey)
        hideOverflowHint()
        if usesScrolling { DesignSettings.shared.useScrollingTabs?() }
    }

    /// Places the hint after the tabs' viewport (and its +), on the tabs' line.
    func layoutOverflowHint() {
        guard let hint = overflowHint, !hint.isHidden else { return }
        let width = hint.preferredWidth
        let height = min(metrics.tabHeight, bounds.height)
        hint.frame = CGRect(x: bounds.width - metrics.stripHorizontalPadding - width, y: tabTop, width: width, height: height)
    }

    private func makeOverflowHint() -> TabOverflowHintView {
        let hint = TabOverflowHintView()
        hint.isHidden = true
        hint.onAnswer = { [weak self] usesScrolling in self?.answerOverflowHint(usesScrolling: usesScrolling) }
        contentView.addSubview(hint)
        overflowHint = hint
        return hint
    }
}
