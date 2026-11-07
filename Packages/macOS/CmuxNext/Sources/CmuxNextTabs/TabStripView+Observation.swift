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
                TokenSnapshot(metrics: TabStripMetrics(), titleFont: Typography.tabTitle.pointSize, topRowLine: TopRowLineLook.tunable.value)
            }
            var line: TopRowLineLook?
            for await snapshot in changes {
                guard let self else { return }
                if snapshot.metrics != self.metrics || snapshot.titleFont != self.tabTitleFontSize {
                    self.applyTokens(animated: true)
                }
                // Another line in Debug Settings: a top-row strip lays its window out again once.
                if let line, line != snapshot.topRowLine, let window = self.window, WindowTitlebar.isInTopRow(self) {
                    WindowTitlebar.layOutTopRowAgain(in: window)
                }
                line = snapshot.topRowLine
            }
        }
    }

    /// Current tab title font size, for change detection.
    var tabTitleFontSize: CGFloat { cells.values.first?.titleFont.pointSize ?? Typography.tabTitle.pointSize }
}
