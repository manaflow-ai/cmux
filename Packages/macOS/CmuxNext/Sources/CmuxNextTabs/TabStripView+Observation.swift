import AppKit
import CmuxNextCompat
import CmuxNextDesign

// The model and design-token observation (split from TabStripView.swift, cx-5jqsb).
extension TabStripView {
    func startObserving() {
        guard observationTask == nil else { return }
        let model = model
        observationTask = Task { [weak self] in
            let changes = ObservationStream {
                ModelSnapshot(
                    tabs: model.tabs,
                    groups: model.groups,
                    selectedID: model.selectedID,
                    style: model.style,
                    showsNewTabButton: model.showsNewTabButton
                )
            }
            for await _ in changes {
                guard let self else { return }
                self.sync(fromModel: true)
            }
        }
    }

    /// Re-applies design tokens whenever `DesignSettings` changes. Reading
    /// the tokens inside `Observations` registers the dependency; nothing is
    /// cached in statics.
    func startObservingTokens() {
        guard tokenObservationTask == nil else { return }
        tokenObservationTask = Task { [weak self] in
            let changes = ObservationStream { TokenSnapshot(metrics: TabStripMetrics(), titleFont: Typography.body.pointSize) }
            for await snapshot in changes {
                guard let self else { return }
                if snapshot.metrics != self.metrics || snapshot.titleFont != self.tabTitleFontSize {
                    self.applyTokens(animated: true)
                }
            }
        }
    }

    /// Current tab title font size, for change detection.
    var tabTitleFontSize: CGFloat { cells.values.first?.titleFont.pointSize ?? Typography.body.pointSize }

    func applyTokens(animated: Bool) {
        metrics = customMetrics ?? TabStripMetrics()
        hoverCard.tokensChanged()
        geometryDidChange()
        let font = Typography.body
        for cell in cells.values {
            cell.metrics = metrics
            cell.titleFont = font
        }
        for chip in groups.chips.values {
            chip.metrics = metrics
            chip.font = Typography.caption
        }
        groupEditor.hide()
        overflowHint?.applyTokens()
        newTabButton.needsLayout = true
        glassView?.cornerRadius = metrics.cornerRadius + metrics.stripVerticalPadding
        invalidateIntrinsicContentSize()
        lastViewportWidth = -1
        needsLayout = true
        layoutSubtreeIfNeeded()
        relayout(animated: animated && !reduceMotion)
    }
}
