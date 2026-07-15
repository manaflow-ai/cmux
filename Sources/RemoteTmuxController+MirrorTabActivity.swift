import Foundation

extension RemoteTmuxController {
    /// The live session mirror + tmux window id behind a mirrored window-tab, or
    /// `nil` when `panelId` isn't a mirrored window-tab of `workspaceId` with a
    /// live connection. Shared by the kill routing and the close-confirmation
    /// check so the two can never disagree about which tabs route remotely.
    private func mirrorWindowTarget(workspaceId: UUID, panelId: UUID)
        -> (mirror: RemoteTmuxSessionMirror, windowId: Int)?
    {
        guard let mirror = sessionMirrors.values.first(where: { $0.mirroredWorkspaceId == workspaceId }),
              let windowId = mirror.windowId(forPanel: panelId) else { return nil }
        return (mirror, windowId)
    }

    /// Whether the panel is currently a tmux window tab in a mirrored workspace.
    /// This lets non-interactive socket close paths route or reject before they
    /// mark the tab as a forced local close.
    func isMirrorWindowTab(workspaceId: UUID, panelId: UUID) -> Bool {
        mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) != nil
    }

    /// A tab close was requested in a mirrored workspace → kill that tmux window
    /// on the remote. The local tab is removed when tmux reports `%window-close`,
    /// so the caller should VETO the immediate local close.
    ///
    /// - Returns: `true` if routed to the remote (caller vetoes the local close);
    ///   `false` if there is no live mirror/connection or the panel isn't a
    ///   mirrored window (caller proceeds with the normal local close).
    func handleMirrorTabCloseRequested(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId),
              target.mirror.connection.connectionState == .connected else { return false }
        return target.mirror.connection.send("kill-window -t @\(target.windowId)")
    }

    /// ``MirrorTabActivity`` from the subscription-fed cache (≤~1s stale).
    private func mirrorTabActivityFromCache(
        target: (mirror: RemoteTmuxSessionMirror, windowId: Int)
    ) -> MirrorTabActivity {
        let connection = target.mirror.connection
        let order = connection.windowsByID[target.windowId]?.paneIDsInOrder ?? []
        var states: [Int: RemoteTmuxControlConnection.PaneForegroundState] = [:]
        for paneId in order {
            states[paneId] = connection.paneForegroundStates[paneId]
        }
        return Self.mirrorTabActivity(
            states: states, paneOrder: order,
            activePaneId: connection.activePaneByWindow[target.windowId]
        )
    }

    /// The cached activity answer for a mirrored window-tab, or `nil` when
    /// `panelId` isn't a live mirrored window-tab. Used where a round trip
    /// isn't warranted (the always-warn dialog path).
    func cachedMirrorTabActivity(workspaceId: UUID, panelId: UUID) -> MirrorTabActivity? {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else { return nil }
        return mirrorTabActivityFromCache(target: target)
    }

    /// Returns a fresh close-time answer, or `nil` when tmux cannot answer.
    /// Destructive callers use the optional result to fail closed instead of
    /// treating a stale cached idle sample as permission to kill the window.
    func queryLiveMirrorTabActivity(
        workspaceId: UUID,
        panelId: UUID
    ) async -> MirrorTabActivity? {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else {
            return nil
        }
        let connection = target.mirror.connection
        let windowId = target.windowId
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                connection.queryWindowActivity(windowId: windowId, token: token) { states in
                    guard let states else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: Self.mirrorTabActivity(
                        states: states,
                        paneOrder: connection.windowsByID[windowId]?.paneIDsInOrder
                            ?? Array(states.keys).sorted(),
                        activePaneId: connection.activePaneByWindow[windowId]
                    ))
                }
                // Cancellation can happen before the handler's main-actor task
                // runs. Recheck after registration so either ordering removes
                // the same token through the exact-once finish path.
                if Task.isCancelled {
                    connection.cancelActivityQuery(token: token)
                }
            }
        } onCancel: {
            Task { @MainActor [weak connection] in
                connection?.cancelActivityQuery(token: token)
            }
        }
    }

    /// Live, close-time variant of ``cachedMirrorTabActivity(workspaceId:panelId:)``:
    /// asks tmux NOW (one round trip) instead of trusting the subscription cache,
    /// which tmux only refreshes about once a second — so a command started right
    /// before ⌘W still gets its confirmation, with the fresh command name for the
    /// dialog. Falls back to the cached answer when the query can't run (link
    /// down, reconnecting, target gone). `completion` runs exactly once, on the
    /// main actor.
    func queryMirrorTabActivity(
        workspaceId: UUID, panelId: UUID, completion: @escaping (MirrorTabActivity) -> Void
    ) {
        let cached = cachedMirrorTabActivity(workspaceId: workspaceId, panelId: panelId)
        queryLiveMirrorTabActivity(workspaceId: workspaceId, panelId: panelId) { activity in
            completion(activity ?? cached ?? MirrorTabActivity(
                hasActiveCommand: false,
                activeCommandName: nil
            ))
        }
    }

    private func queryLiveMirrorTabActivity(
        workspaceId: UUID,
        panelId: UUID,
        completion: @escaping (MirrorTabActivity?) -> Void
    ) {
        guard let target = mirrorWindowTarget(workspaceId: workspaceId, panelId: panelId) else {
            completion(nil)
            return
        }
        // The connection bounds and exact-once finishes every query across a
        // reply, deadline, send failure, or stream reset.
        target.mirror.connection.queryWindowActivity(windowId: target.windowId) { states in
            guard let states else {
                completion(nil)
                return
            }
            let connection = target.mirror.connection
            completion(Self.mirrorTabActivity(
                states: states,
                paneOrder: connection.windowsByID[target.windowId]?.paneIDsInOrder
                    ?? Array(states.keys).sorted(),
                activePaneId: connection.activePaneByWindow[target.windowId]
            ))
        }
    }
}
