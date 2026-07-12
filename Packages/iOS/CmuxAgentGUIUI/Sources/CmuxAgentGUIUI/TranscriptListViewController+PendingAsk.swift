#if os(iOS)
import CmuxAgentGUIProjection
import CmuxAgentReplica
import UIKit

extension TranscriptListViewController {
    func applyPendingAskInteraction(
        answeringAskID: String?,
        failedAskID: String?,
        onAnswer: @escaping (PendingAsk, Int) -> Void,
        onShowTerminal: @escaping () -> Void
    ) {
        self.answeringAskID = answeringAskID
        self.failedAskID = failedAskID
        self.onAnswer = onAnswer
        self.onShowTerminal = onShowTerminal
        guard isViewLoaded else { return }
        var snapshot = dataSource.snapshot()
        let asks = snapshot.itemIdentifiers.filter { id in
            guard let row = rowsByID[id] else { return false }
            if case .pendingAsk = row.rowKind { return true }
            return false
        }
        snapshot.reconfigureItems(asks)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
#endif
