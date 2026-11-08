import Bonsplit
import CmuxWorkspaces
import Foundation

struct SessionSimulatorPanelSnapshot: Codable, Sendable {
    var deviceUDID: String?
    var runtimeIdentifier: String?
    var deviceTypeIdentifier: String?
}

extension Workspace {
    func simulatorSessionSnapshot(for panel: any Panel) -> SessionSimulatorPanelSnapshot? {
        guard let simulatorPanel = panel as? SimulatorPanel else { return nil }
        return SessionSimulatorPanelSnapshot(
            deviceUDID: simulatorPanel.selectedDeviceID,
            runtimeIdentifier: simulatorPanel.selectedRuntimeIdentifier,
            deviceTypeIdentifier: simulatorPanel.selectedDeviceTypeIdentifier
        )
    }

    func restoreSimulatorPanel(
        from snapshot: SessionPanelSnapshot,
        inPane paneId: PaneID
    ) -> UUID? {
        guard let simulatorPanel = newSimulatorSurface(
            inPane: paneId,
            preferredDeviceID: snapshot.simulator?.deviceUDID,
            preferredRuntimeIdentifier: snapshot.simulator?.runtimeIdentifier,
            preferredDeviceTypeIdentifier: snapshot.simulator?.deviceTypeIdentifier,
            focus: false,
            restoringSession: true
        ) else {
            return nil
        }
        applySessionPanelMetadata(snapshot, toPanelId: simulatorPanel.id)
        return simulatorPanel.id
    }
}
