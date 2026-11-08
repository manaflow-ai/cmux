import Foundation

/// Owns the focus-neutral transaction boundary for remote-tmux topology bookkeeping.
@MainActor
final class RemoteTmuxMirrorMutationCoordinator {
    private var activeSnapshot: RemoteTmuxMirrorMutationSnapshot?

    var suppressesFocusActivation: Bool { activeSnapshot != nil }

    @discardableResult
    func perform<Result>(
        in workspace: Workspace,
        operation: () throws -> Result
    ) rethrows -> Result {
        if activeSnapshot != nil {
            return try operation()
        }

        let snapshot = RemoteTmuxMirrorMutationSnapshot(workspace: workspace)
        activeSnapshot = snapshot
        defer {
            snapshot.restore(in: workspace)
            activeSnapshot = nil
            if snapshot.requiresReplacementFocus(in: workspace) {
                workspace.scheduleFocusReconcile()
            }
        }
        return try operation()
    }
}

extension Workspace {
    @discardableResult
    func performRemoteTmuxMirrorMutation<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        try remoteTmuxMirrorMutations.perform(in: self, operation: operation)
    }

    @discardableResult
    func removeRemoteTmuxDisplayPane(_ panelId: UUID) -> Bool {
        performRemoteTmuxMirrorMutation {
            closePanel(panelId, force: true)
        }
    }
}
