import Foundation

extension CmuxTuiSurfaceProvider {
    /// Closes a Cloud terminal, falling back to its daemon tab when the process already exited.
    func closeTerminal(_ id: SurfaceResourceID, fallbackTabID: String?) async throws {
        pendingRemoteCreations.removeValue(forKey: id)
        do {
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTerminalArguments(socketPath: $0, terminalID: id.key) }
        } catch {
            guard let tabID = fallbackTabID ?? tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await runCloseCommand { CloudTuiCommandLine.closeTabArguments(socketPath: $0, tabID: tabID) }
        }
        closeLocalPanes(showing: [id]); catalog.remove(id, from: self); scheduleRefresh()
    }

    private func closeLocalPanes(showing ids: [SurfaceResourceID]) {
        let wanted = Set(ids)
        for projection in catalog.snapshot.projections where wanted.contains(projection.resource) {
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        }
    }
}
