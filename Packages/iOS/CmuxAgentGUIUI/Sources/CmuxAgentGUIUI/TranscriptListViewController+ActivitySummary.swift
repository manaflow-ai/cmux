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
        let snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(row.rowID) != nil else { return }
        applySnapshot(
            snapshot,
            reconfiguring: [row.rowID],
            anchor: captureAnchor(),
            invalidatingLayout: true
        )
    }
}
#endif
