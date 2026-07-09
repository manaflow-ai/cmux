public import Foundation

extension WorkspaceCloseCoordinator {
    /// Closes a panel because its child process exited (e.g. the user hit
    /// Ctrl+D). This path must never prompt: the process is already gone, and
    /// Ghostty emits the `SHOW_CHILD_EXITED` action specifically so the host app
    /// can decide what to do.
    ///
    /// Lifts the legacy `TabManager.closePanelAfterChildExited(tabId:surfaceId:)`
    /// routing decision one-for-one. The decision is pure over the window's
    /// ``WorkspacesModel`` (the workspace lookup, the `model.tabs.count` last-
    /// workspace test) and the panel/remote state the ``WorkspaceCloseHosting``
    /// child-exit seam reads; each branch's effect (the remote-session-ended
    /// mark, the persistent-remote attach-failed mark, the runtime-surface close,
    /// the last-workspace window close, and the route-through-`closeWorkspace`
    /// teardown) inverts through that host. The branch order and the
    /// short-circuit evaluation of `shouldDemoteWorkspaceAfterChildExit` /
    /// `panelCount` are the observable behavior, preserved exactly.
    ///
    /// No-op when the host is unattached (the window wires it before any close).
    public func closePanelAfterChildExited(tabId: UUID, surfaceId: UUID) {
        guard let host else { return }
        guard let tab = model.tabs.first(where: { $0.id == tabId }) else { return }
        guard tab.panelExists(surfaceId) else { return }
        let keepsPersistentRemoteSurfaceOpen =
            host.keepsPersistentRemoteSurfaceOpenAfterChildExit(tab, surfaceId: surfaceId)
        if !keepsPersistentRemoteSurfaceOpen,
           host.shouldDemoteWorkspaceAfterChildExit(tab, surfaceId: surfaceId) {
            host.markRemoteTerminalSessionEnded(tab, surfaceId: surfaceId)
        }
        let handlesRemoteExitThroughWorkspace =
            host.panelCount(tab) <= 1
            && host.shouldDemoteWorkspaceAfterChildExit(tab, surfaceId: surfaceId)

        host.logChildExitCloseDecision(
            tab,
            surfaceId: surfaceId,
            workspaceCount: model.tabs.count,
            handlesRemoteExitThroughWorkspace: handlesRemoteExitThroughWorkspace,
            keepsPersistentRemoteSurfaceOpen: keepsPersistentRemoteSurfaceOpen
        )

        // A persistent SSH workspace must never silently replace a failed remote
        // attach with a local login shell. Keep the exited surface visible so the
        // user can see the error and retry instead of making a detached remote
        // workspace look local after relaunch.
        if keepsPersistentRemoteSurfaceOpen {
            host.markPersistentRemotePTYAttachFailed(tab, surfaceId: surfaceId)
            return
        }

        // Route the last remote child exit through Workspace close handling so
        // remote teardown and replacement-panel logic run before TabManager
        // considers removing the workspace.
        if handlesRemoteExitThroughWorkspace {
            host.closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
            return
        }

        // Child-exit on the last panel should collapse the workspace, matching
        // explicit close semantics (and close the window when it was the last
        // workspace).
        if host.panelCount(tab) <= 1 {
            if model.tabs.count <= 1 {
                if !host.closeWindowForLastChildExit(workspaceId: tabId) {
                    // Headless/test fallback when no AppDelegate window context exists.
                    host.closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
                }
            } else {
                closeWorkspace(tab, recordHistory: false)
            }
            return
        }

        host.closeRuntimeSurface(tabId: tabId, surfaceId: surfaceId)
    }
}
