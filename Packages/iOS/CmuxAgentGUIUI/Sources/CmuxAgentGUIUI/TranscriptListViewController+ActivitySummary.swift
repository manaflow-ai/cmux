#if os(iOS)
import CmuxAgentGUIProjection
import UIKit

extension TranscriptListViewController {
    func pruneExpandedActivityTurns(retaining rows: [TranscriptRow]) {
        expandedActivityTurnIDs.formIntersection(rows.compactMap(\.turnID))
    }

    func toggleActivitySummary(row: TranscriptRow) {
        guard let turnID = row.turnID else { return }
        if expandedActivityTurnIDs.remove(turnID) == nil {
            expandedActivityTurnIDs.insert(turnID)
        }
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(row.rowID) != nil else { return }
        snapshot.reconfigureItems([row.rowID])
        UIView.performWithoutAnimation {
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()
        }
    }
}
#endif
