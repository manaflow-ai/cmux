import CMUXAgentLaunch
import Foundation

// MARK: - Socket-layer helpers

extension FeedCoordinator {
    /// Main-actor snapshot used by app and typed control contexts.
    @MainActor
    func snapshot(pendingOnly: Bool) -> [WorkstreamItem] {
        guard let store else { return [] }
        return pendingOnly ? store.pending : store.items
    }

    /// Removes a non-blocking Feed item from the shared store and its
    /// persisted projection. Pending decisions stay protected by the UI.
    @MainActor
    func removeItem(id: UUID) async -> Bool {
        guard let store else { return false }
        return (try? await store.removeItem(id: id)) == true
    }

    /// Runs the same terminal navigation used by Feed rows and returns only
    /// after the UI route has accepted or rejected the target. `feed.jump` is
    /// a user-triggered main-actor command, so its response stays ordered after
    /// the visible focus change instead of acknowledging a queued task.
    @MainActor
    func requestFocusIfPossible(workstreamId: String) -> Bool {
        guard let target = jumpResolver.resolve(workstreamId) else { return false }
        return AppDelegate.shared?.routeFeedFocus(
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId
        ) ?? false
    }

    /// Fires a best-effort focus for the given `workstreamId`. Returns
    /// `true` if a target was found and the focus commands were
    /// dispatched. Runs on the main actor because the focus commands
    /// touch AppKit state.
    func focusIfPossible(workstreamId: String) async -> Bool {
        guard let target = await jumpResolver.resolveOffMain(workstreamId) else {
            return false
        }
        return await MainActor.run {
            AppDelegate.shared?.routeFeedFocus(
                workspaceId: target.workspaceId,
                surfaceId: target.surfaceId
            ) ?? false
        }
    }

    /// Resolves `workstreamId` to a `(workspace, surface)` pair and
    /// types the user's `text` into that surface, followed by Return.
    /// Used by Stop-kind cards so the user can reply to Claude from
    /// the Feed without switching focus to the terminal.
    @discardableResult
    func sendTextToWorkstream(workstreamId: String, text: String) async -> Bool {
        guard let target = await jumpResolver.resolveOffMain(workstreamId) else {
            return false
        }
        return await MainActor.run {
            AppDelegate.shared?.routeFeedText(
                surfaceId: target.surfaceId,
                text: text
            ) ?? false
        }
    }
}
