import CmuxWorkspaces
import Foundation

/// The highlighted checklist mutation selected by a focused prefix chord.
struct PrefixChordChecklistToggleTarget {
    let itemID: UUID
    let nextState: WorkspaceChecklistItem.State

    init?(
        items: [WorkspaceChecklistItem],
        highlightedItemID: UUID?,
        isEligible: Bool
    ) {
        guard isEligible,
              let highlightedItemID,
              let item = items.first(where: { $0.id == highlightedItemID }) else {
            return nil
        }
        itemID = item.id
        nextState = item.state == .completed ? .pending : .completed
    }
}
