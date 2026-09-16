import Foundation

extension Workspace {
    /// Keeps a failed Cloud placement write visible without blocking the workspace.
    func presentCloudPlacementFailure(_ error: Error, machine: SurfaceMachineID) {
        let requestID = cloudPaneCreationFailureStore.beginRequest()
        let title = String(
            localized: "cloudPane.layoutSyncFailed.title",
            defaultValue: "Couldn’t update the machine workspace"
        )
        let recovery = String(
            localized: "cloudPane.layoutSyncFailed.detail",
            defaultValue: "Your local pane change was kept, but the machine layout could not be synchronized. Reopen the machine workspace to see its current layout."
        )
        cloudPaneCreationFailureStore.present(
            machine: machine,
            error: error,
            requestID: requestID,
            title: title,
            recoveryText: recovery
        )
    }
}
