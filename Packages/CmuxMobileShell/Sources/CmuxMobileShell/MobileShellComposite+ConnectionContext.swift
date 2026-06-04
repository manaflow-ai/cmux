/// ``MobileShellComposite`` is the facade-side context for its carved-out
/// ``MobileConnectionCoordinator``: it supplies the sign-in gate, applies
/// remote workspace lists to the workspace model, manages connection-scoped
/// tasks, and tears down the output pipeline when the client is cleared.
/// `isSignedIn`, `selectedWorkspaceID`, `cancelRemoteOperationTasks`,
/// `applyRemoteWorkspaceList`, and `syncSelectedTerminalForWorkspace` are
/// witnessed by members in the main class body.
extension MobileShellComposite: MobileConnectionContext {
    func remoteClientWasCleared() {
        terminalOutput.stopTerminalRefreshPolling()
        cancelRemoteOperationTasks()
        terminalOutput.resetTerminalOutputTracking()
    }

    func connectionDidEstablish() {
        terminalOutput.startTerminalRefreshPolling()
    }

    func clearRawTerminalInputBuffer() {
        rawTerminalInputBuffer.clear()
    }

    func applyPreviewTicket(workspaceID: String, terminalID: String?) {
        workspaceModel.applyPreviewTicket(workspaceID: workspaceID, terminalID: terminalID)
    }

    func ensurePreviewWorkspaceSelection() {
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = workspaces.first?.id
        }
        syncSelectedTerminalForWorkspace()
    }
}
