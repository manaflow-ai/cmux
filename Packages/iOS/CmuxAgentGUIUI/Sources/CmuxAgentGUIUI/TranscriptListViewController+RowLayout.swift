#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

extension TranscriptListViewController {
    func layoutForRow(rowID: TranscriptRowID, width: CGFloat) -> TranscriptRowLayoutResult? {
        guard let row = rowsByID[rowID], let spacing = spacingByID[rowID] else {
            return nil
        }
        let askState = askLayoutState(for: row)
        if let cached = heightCache[rowID],
           cached.row == row,
           cached.width == width,
           cached.density == currentDensity,
           cached.askState == askState {
            return cached.layout
        }
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        let layout = TranscriptRowLayout.layout(
            row: row,
            width: width,
            spacing: spacing,
            scale: scale,
            askState: askState,
            traitCollection: traitCollection
        )
        layoutComputationCount += 1
        heightCache[rowID] = TranscriptRowLayoutCacheEntry(
            row: row,
            width: width,
            density: currentDensity,
            spacing: spacing,
            height: layout.height,
            askState: askState,
            layout: layout
        )
        return layout
    }

    func resetLayoutComputationCount() {
        layoutComputationCount = 0
        backgroundLayoutComputationCount = 0
    }

    func invalidateAllRowLayouts() {
        cancelInitialLayout()
        heightCache.removeAll(keepingCapacity: true)
        if isViewLoaded,
           collectionView != nil,
           dataSource != nil,
           dataSource.snapshot().itemIdentifiers.isEmpty,
           currentRows.count >= 100,
           collectionView.bounds.width > 1 {
            scheduleInitialLayout(for: currentRows)
            return
        }
        guard isViewLoaded,
              collectionView != nil,
              dataSource != nil,
              !currentRows.isEmpty
        else {
            (collectionView?.collectionViewLayout as? TranscriptCollectionLayout)?.invalidateLayout()
            return
        }
        let snapshot = dataSource.snapshot()
        applySnapshot(
            snapshot,
            reconfiguring: Set(snapshot.itemIdentifiers),
            anchor: captureAnchor(pinningExactBottomRest: true),
            invalidatingLayout: true
        )
    }

    private func askLayoutState(for row: TranscriptRow) -> TranscriptAskLayoutState {
        guard case .pendingAsk(let ask) = row.rowKind else { return .idle }
        return TranscriptAskLayoutState(
            isAnswering: answeringAskID == ask.id,
            hasFailed: failedAskID == ask.id
        )
    }
}
#endif
