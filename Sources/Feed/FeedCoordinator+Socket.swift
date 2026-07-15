import CMUXAgentLaunch
import Foundation

// MARK: - Socket-layer helpers

extension FeedCoordinator {
    /// Thread-safe snapshot of the store's items; hops to main to read
    /// the observable state (only if called off-main).
    func snapshot(pendingOnly: Bool) -> [WorkstreamItem] {
        let body: @Sendable () -> [WorkstreamItem] = {
            MainActor.assumeIsolated {
                guard let store = FeedCoordinator.shared.store else { return [] }
                return pendingOnly ? store.pending : store.items
            }
        }
        if Thread.isMainThread {
            return body()
        }
        return DispatchQueue.main.sync(execute: body)
    }

    /// Parses `workstreamId` in the form `<agent>-<sessionId>` and
    /// looks up the matching hook-session entry in
    /// `~/.cmuxterm/<agent>-hook-sessions.json` (written by
    /// `cmux <agent>-hook session-start`). Returns `true` if a match
    /// was found so the UI can gate the jump gesture.
    ///
    /// Actual focus (workspace.select + surface.focus) is scheduled via
    /// `FeedJumpResolver.focusIfPossible` on the main actor.
    func resolvePossibleSurface(for workstreamId: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId) else {
            return false
        }
        return FeedJumpResolver.lookup(agent: parsed.agent, sessionId: parsed.sessionId) != nil
    }

    /// Fires a best-effort focus for the given `workstreamId`. Returns
    /// `true` if a target was found and the focus commands were
    /// dispatched. Runs on the main actor because the focus commands
    /// touch AppKit state.
    @MainActor
    func focusIfPossible(workstreamId: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId),
              let target = FeedJumpResolver.lookup(
                agent: parsed.agent, sessionId: parsed.sessionId
              )
        else { return false }
        FeedJumpResolver.focus(workspaceId: target.workspaceId, surfaceId: target.surfaceId)
        return true
    }

    /// Resolves `workstreamId` to a `(workspace, surface)` pair and
    /// types the user's `text` into that surface, followed by Return.
    /// Used by Stop-kind cards so the user can reply to Claude from
    /// the Feed without switching focus to the terminal.
    @MainActor
    @discardableResult
    func sendTextToWorkstream(workstreamId: String, text: String) -> Bool {
        guard let parsed = FeedJumpResolver.parse(workstreamId),
              let target = FeedJumpResolver.lookup(
                agent: parsed.agent, sessionId: parsed.sessionId
              )
        else { return false }
        FeedJumpResolver.sendText(
            workspaceId: target.workspaceId,
            surfaceId: target.surfaceId,
            text: text
        )
        return true
    }
}
