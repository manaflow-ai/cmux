import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

struct TerminalHierarchyMoveAction {
    let intent: MobileTerminalReorderIntent
    let optimisticOrder: [MobileTerminalPreview.ID]

    init?(
        source: IndexSet,
        destination: Int,
        pane: TerminalHierarchyPaneSnapshot
    ) {
        guard source.count == 1,
              let sourceIndex = source.first,
              pane.rows.indices.contains(sourceIndex),
              let intent = MobileTerminalReorderIntent(
                  terminalID: pane.rows[sourceIndex].id,
                  sourceIndex: sourceIndex,
                  destinationIndex: destination,
                  pane: pane.pane
              ),
              let optimisticOrder = intent.applying(to: pane.rows.map(\.id)) else {
            return nil
        }
        self.intent = intent
        self.optimisticOrder = optimisticOrder
    }

    @MainActor
    func perform(
        workspaceID: MobileWorkspacePreview.ID,
        reorderGate: MobileTerminalReorderGate,
        reorderTerminal: @escaping (
            MobileTerminalReorderIntent,
            MobileTerminalReorderReservation
        ) async -> Result<Void, MobileWorkspaceMutationFailure>,
        updateOptimisticOrder: @escaping ([MobileTerminalPreview.ID]?) -> Void,
        completion: @escaping (TerminalHierarchyMoveActionOutcome) -> Void
    ) {
        guard let reservation = reorderGate.reserve(
            workspaceID: workspaceID,
            paneID: intent.paneID
        ) else {
            completion(.unavailable)
            return
        }
        updateOptimisticOrder(optimisticOrder)
        Task { @MainActor in
            let result = await reorderTerminal(intent, reservation)
            updateOptimisticOrder(nil)
            completion(.completed(result))
        }
    }
}
