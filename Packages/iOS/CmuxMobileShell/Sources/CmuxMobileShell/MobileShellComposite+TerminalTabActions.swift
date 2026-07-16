internal import CmuxMobileRPC
public import CmuxMobileShellModel
import Foundation

/// Tab-level mutations issued from the surface strip and workspace map:
/// closing one terminal tab. Lives in an extension file to respect
/// `MobileShellComposite.swift`'s length budget.
extension MobileShellComposite {
    /// Close one terminal tab on the Mac (`terminal.close`).
    ///
    /// One optimistic mutation path: the tab is removed locally first (strip,
    /// pager, and pane layout update instantly), the previous workspace
    /// snapshot is kept for rollback, and the authoritative tree re-arrives
    /// via the next workspace-list sync. The Mac refuses to close a
    /// workspace's last terminal, and so does this guard.
    public func closeTerminal(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) {
        guard let workspace = workspaces.first(where: { $0.id == workspaceID }),
              workspace.terminals.contains(where: { $0.id == terminalID }),
              workspace.terminals.count > 1 else {
            return
        }
        let previousWorkspace = workspace
        removeTerminalLocally(workspaceID: workspaceID, terminalID: terminalID)
        guard let client = remoteClient else { return }
        let requestedWorkspaceID = remoteWorkspaceID(for: workspaceID)
        let generation = connectionGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await client.sendRequest(
                    MobileCoreRPCClient.requestData(
                        method: "terminal.close",
                        params: [
                            "workspace_id": requestedWorkspaceID.rawValue,
                            "terminal_id": terminalID.rawValue,
                        ]
                    )
                )
            } catch {
                guard generation == self.connectionGeneration, !Task.isCancelled else { return }
                // The tab still exists on the Mac; restore the pre-close
                // snapshot instead of leaving a ghost-removed tab until the
                // next unrelated list sync.
                self.mutateForegroundWorkspaces { list in
                    guard let index = list.firstIndex(where: { $0.id == workspaceID }) else { return }
                    list[index] = previousWorkspace
                }
                guard !self.disconnectForAuthorizationFailureIfNeeded(error) else { return }
                self.markMacConnectionUnavailableIfNeeded(after: error)
                self.applyOperationalError(error)
            }
        }
    }

    private func removeTerminalLocally(
        workspaceID: MobileWorkspacePreview.ID,
        terminalID: MobileTerminalPreview.ID
    ) {
        mutateForegroundWorkspaces { list in
            guard let index = list.firstIndex(where: { $0.id == workspaceID }) else { return }
            list[index].terminals.removeAll { $0.id == terminalID }
            list[index].paneLayout = list[index].paneLayout?.removingTab(terminalID)
        }
        if selectedTerminalID == terminalID {
            syncSelectedTerminalForWorkspace()
        }
    }
}
