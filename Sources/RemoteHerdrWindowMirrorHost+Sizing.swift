import AppKit
import CmuxNestedTopology
import Foundation

@MainActor
extension RemoteHerdrWindowMirrorHost {
    /// Feed-forward container size ingest (tmux ``noteContainerSize``).
    func noteContainerSize(pointSize: CGSize, scale: CGFloat) {
        guard !isTornDown else { return }
        guard pointSize.width > 0, pointSize.height > 0 else { return }
        containerSizePt = pointSize
        containerScale = max(1, scale)
        renderFrameSize = pointSize
        setNeedsSizingPass()
    }

    func setNeedsSizingPass() {
        guard !sizingPassScheduled, !isTornDown else { return }
        sizingPassScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sizingPassScheduled = false
            self.performSizingPassNow()
        }
    }

    /// Claims a client grid from Herdr when the visible tab's container changes.
    func performSizingPassNow() {
        guard !isTornDown, isVisibleForSizing else { return }
        guard let containerSizePt,
              containerSizePt.width > 0,
              containerSizePt.height > 0
        else { return }

        // Cell metrics: prefer the active pane, then any pane in stable order.
        var cellWidth: Double = 8
        var cellHeight: Double = 16
        let samplePanels: [TerminalPanel] = {
            if let activePaneID, let panel = panelsByPaneId[activePaneID] {
                return [panel]
            }
            return panelsByPaneId.keys.sorted().compactMap { panelsByPaneId[$0] }
        }()
        for panel in samplePanels {
            if let sample = panel.surface.rawSizingSample(),
               sample.cellWidthPx > 0,
               sample.cellHeightPx > 0 {
                let scale = Double(max(1, sample.backingScale ?? containerScale))
                cellWidth = Double(sample.cellWidthPx) / scale
                cellHeight = Double(sample.cellHeightPx) / scale
                break
            }
        }

        guard let grid = sizing.clientGrid(
            contentWidth: Double(containerSizePt.width),
            contentHeight: Double(containerSizePt.height),
            cellWidth: cellWidth,
            cellHeight: cellHeight
        ) else { return }

        if let last = lastClaimedClientGrid,
           last.cols == grid.cols,
           last.rows == grid.rows {
            return
        }

        // Claim against the active (or first) pane — Herdr owns the grid and
        // redistributes via layout events, matching tmux refresh-client -C.
        let claimPane = activePaneID
            ?? renderedLayout?.paneIDsInOrder.first
            ?? panelsByPaneId.keys.sorted().first
        guard let claimPane else { return }
        onResizePaneRequest?(claimPane, grid.cols, grid.rows)
        lastClaimedClientGrid = grid
    }

    func visibleHostingWindow() -> NSWindow? {
        if let hostProbeView, let window = hostProbeView.window { return window }
        for panel in panelsByPaneId.values {
            if let window = panel.hostedView.window { return window }
        }
        return nil
    }
}
