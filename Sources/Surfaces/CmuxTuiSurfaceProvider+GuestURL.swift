import CmuxSurfaceCatalogModel
import Foundation

extension CmuxTuiSurfaceProvider {
    /// Exact terminal projections are the sole authority for guest URL routing.
    /// A VM's default workspace and the user's selected workspace are irrelevant.
    func guestURLContext(terminalID: String) -> TerminalLinkOpenRequest? {
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        let projections = catalog.projections(of: id)
        guard isRegisteredInCatalog(), !isFeatureSuspended,
              projections.count == 1, let projection = projections.first,
              AppDelegate.shared?.workspaceFor(tabId: projection.workspaceID)?.panels[projection.panelID] != nil else { return nil }
        return TerminalLinkOpenRequest(rawValue: "", sourceWorkspaceId: projection.workspaceID,
                                      sourcePanelId: projection.panelID, workingDirectory: nil, focus: false)
    }

    func updateGuestURLMembership() {
        let version = catalog.projectionVersions[machine, default: 0]
        guard guestURLProjectionVersion != version else { return }
        guestURLProjectionVersion = version
        guestURLTerminalIDs = catalog.projectedTerminalIDs(on: machine)
        guestURLService?.updateTerminals(guestURLTerminalIDs)
    }

    func configureGuestURLOpen(link: CloudMachineLink, socketPath: String) {
        if guestURLService == nil {
            guestURLService = CloudGuestURLService(machineID: machineID, executable: CloudTuiClientPaths.clientURL()) { [weak self] in
                self?.guestURLContext(terminalID: $0)
            }
        }
        updateGuestURLMembership()
        guestURLService?.update(link: link, socketPath: socketPath, terminals: guestURLTerminalIDs)
    }
}
