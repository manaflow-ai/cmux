import Foundation

/// Decides when a window's creation reveal may move the Cloud tree selection.
///
/// The tree selects the new workspace row once, when the row first exists, and
/// only while the selection is still the one the tree had when the create
/// began. A withdrawn create puts that selection back if the revealed row is
/// still selected. Any newer selection, user or programmatic, ends the reveal,
/// including one that leaves and comes back to the same row.
/// A tree that mounts while a create is already in flight ignores that create,
/// so a remount never replays an old reveal over the restored selection.
struct CloudTreeCreationRevealPresentation {
    enum Action: Equatable {
        case select(String)
        case restore(String?)
    }

    private struct Selection: Equatable {
        var nodeID: String?
        var revision: Int
    }

    private enum Phase {
        case idle
        case waiting(baseline: Selection)
        case revealed(Selection, baseline: String?)
    }

    private var token: UUID?
    private var phase = Phase.idle
    private var isPrimed = false
    private var revision = 0

    /// Records a selection change the tree did not make programmatically.
    mutating func noteSelectionChange() {
        revision += 1
    }

    mutating func update(
        request: CloudWorkspaceCreationReveal?,
        selectedNodeID: String?,
        contains: (String) -> Bool
    ) -> Action? {
        defer { isPrimed = true }
        guard let request else { return nil }
        let selection = Selection(nodeID: selectedNodeID, revision: revision)
        if request.token != token {
            token = request.token
            phase = isPrimed ? .waiting(baseline: selection) : .idle
        }
        switch phase {
        case .idle:
            return nil
        case .waiting(let baseline):
            guard !request.isWithdrawn, selection == baseline else {
                phase = .idle
                return nil
            }
            guard let id = request.nodeID, contains(id) else { return nil }
            return .select(id)
        case .revealed(let revealed, let baseline):
            guard selection == revealed else {
                phase = .idle
                return nil
            }
            guard request.isWithdrawn else { return nil }
            phase = .idle
            return .restore(baseline)
        }
    }

    /// Records that the tree selected the row a `.select` asked for. Until it
    /// does, the reveal keeps waiting, so a row the outline view could not
    /// resolve or select yet is retried on the next update.
    mutating func didSelect(_ id: String) {
        guard case .waiting(let baseline) = phase else { return }
        phase = .revealed(Selection(nodeID: id, revision: revision), baseline: baseline.nodeID)
    }
}
