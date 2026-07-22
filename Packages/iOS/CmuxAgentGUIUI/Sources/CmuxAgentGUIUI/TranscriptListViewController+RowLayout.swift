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
            askState: askState
        )
        layoutComputationCount += 1
        heightCache[rowID] = TranscriptRowLayoutCacheEntry(
            row: row,
            width: width,
            density: currentDensity,
            height: layout.height,
            askState: askState,
            layout: layout
        )
        return layout
    }

    func resetLayoutComputationCount() {
        layoutComputationCount = 0
    }

    func invalidateAllRowLayouts() {
        heightCache.removeAll(keepingCapacity: true)
        (collectionView?.collectionViewLayout as? TranscriptCollectionLayout)?.invalidateLayout()
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
