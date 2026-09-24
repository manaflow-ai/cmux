import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    func closeTerminal(_ id: SurfaceResourceID) async throws {
        try await closeTerminal(id, fallbackTabID: nil)
    }

    /// Closes a Cloud terminal, falling back to its daemon tab when the process already exited.
    func closeTerminal(_ id: SurfaceResourceID, fallbackTabID: String?) async throws {
        let pendingTabID = pendingRemoteCreations[id]?.tabID
        do {
            _ = try await runCloseCommand { CloudTuiRequests.closeTerminalArguments(socketPath: $0, terminalID: id.key) }
        } catch {
            guard let tabID = fallbackTabID ?? pendingTabID ?? tabByTerminal[id.key], Self.isSelectorNotFound(error) else { throw error }
            _ = try await runCloseCommand { CloudTuiRequests.closeTabArguments(socketPath: $0, tabID: tabID) }
        }
        pendingRemoteCreations.removeValue(forKey: id)
        closeLocalPanes(showing: [id]); catalog.remove(id, from: self); scheduleRefresh()
    }

    private func closeLocalPanes(showing ids: [SurfaceResourceID]) {
        let wanted = Set(ids)
        for projection in catalog.projections where wanted.contains(projection.resource) {
            SurfacePaneFactory.close(panelID: projection.panelID, in: projection.workspaceID)
        }
    }
}
