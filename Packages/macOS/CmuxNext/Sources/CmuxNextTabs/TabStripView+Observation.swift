import AppKit
import CmuxNextCompat
import CmuxNextDesign

// The model and design-token observation (split from TabStripView.swift, cx-5jqsb).
extension TabStripView {
    func startObserving() {
        guard observationTask == nil else { return }
        let model = model
        observationTask = Task { [weak self] in
            let changes = ObservationStream { ModelSnapshot(model) }
            for await _ in changes {
                guard let self else { return }
                self.syncFromModel()
            }
        }
    }

    /// Re-applies design tokens whenever `DesignSettings` changes. Reading
    /// the tokens inside `Observations` registers the dependency; nothing is
    /// cached in statics.
    func startObservingTokens() {
        guard tokenObservationTask == nil else { return }
        tokenObservationTask = Task { [weak self] in
            let changes = ObservationStream {
                TokenSnapshot(metrics: TabStripMetrics(), titleFont: Typography.tabTitle.pointSize, trailingButtons: TabTunables.effectiveTrailingButtons,
                              groupLook: GroupChipGlass.current, cellLooks: CellLooks())
            }
            for await snapshot in changes {
                guard let self else { return }
                // The chips repaint in place: the look never changes their size.
                for chip in self.groups.chips.values { chip.look = snapshot.groupLook }
                if snapshot.cellLooks != self.cellLooks {
                    // The cells resolve these looks as they draw; their metrics are unchanged, so redraw them here.
                    self.cellLooks = snapshot.cellLooks
                    for cell in self.cells.values {
                        cell.layoutLayers()
                        cell.updateColors(animated: false)
                    }
                }
                if snapshot.metrics != self.metrics || snapshot.titleFont != self.tabTitleFontSize || snapshot.trailingButtons != self.trailingButtons {
                    self.applyTokens(animated: true)
                }
            }
        }
    }

    /// Current tab title font size, for change detection.
    var tabTitleFontSize: CGFloat { cells.values.first?.titleFont.pointSize ?? Typography.tabTitle.pointSize }
}
