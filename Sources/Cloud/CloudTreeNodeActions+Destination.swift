import Foundation

extension CloudTreeNodeActions {
    /// Captures the concrete local pane that a new Cloud terminal should use.
    /// Selection can change while the remote creation is reconciling, so the
    /// later materialization must not read global focus again.
    @MainActor
    static func capturedTabDestination(_ workspaceID: UUID?) throws -> SurfaceDestination {
        guard let workspaceID,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceID)?.tabs.first(where: { $0.id == workspaceID }),
              let pane = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
            throw SurfaceCatalogError.destinationNotFound("no selected workspace")
        }
        return .tab(workspaceID: workspaceID, paneID: pane.id.uuidString, index: nil)
    }
}
