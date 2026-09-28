import Foundation

/// Decides when a window's creation reveal may move the Cloud tree selection.
///
/// The tree selects the new workspace row once, when the row first exists, and
/// only while the selection is still the one the tree had when the create
/// began. A withdrawn create puts that selection back if the revealed row is
/// still selected. Any newer selection, user or programmatic, ends the reveal.
/// A tree that mounts while a create is already in flight ignores that create,
/// so a remount never replays an old reveal over the restored selection.
struct CloudTreeCreationRevealPresentation {
    enum Action: Equatable {
        case select(String)
        case restore(String?)
    }

    private enum Phase {
        case idle
        case waiting(baseline: String?)
        case revealed(String, baseline: String?)
    }

    private var token: UUID?
    private var phase = Phase.idle
    private var isPrimed = false

    mutating func update(
        request: CloudWorkspaceCreationReveal?,
        selectedNodeID: String?,
        contains: (String) -> Bool
    ) -> Action? {
        defer { isPrimed = true }
        guard let request else { return nil }
        if request.token != token {
            token = request.token
            phase = isPrimed ? .waiting(baseline: selectedNodeID) : .idle
        }
        switch phase {
        case .idle:
            return nil
        case .waiting(let baseline):
            guard !request.isWithdrawn, selectedNodeID == baseline else {
                phase = .idle
                return nil
            }
            guard let id = request.nodeID, contains(id) else { return nil }
            return .select(id)
        case .revealed(let id, let baseline):
            guard selectedNodeID == id else {
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
    /// resolve yet is retried on the next update.
    mutating func didSelect(_ id: String) {
        guard case .waiting(let baseline) = phase else { return }
        phase = .revealed(id, baseline: baseline)
    }
}
