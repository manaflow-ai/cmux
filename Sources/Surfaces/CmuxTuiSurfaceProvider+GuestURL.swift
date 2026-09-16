import Foundation

extension CmuxTuiSurfaceProvider {
    /// Exact terminal projections are the sole authority for guest URL routing.
    /// A VM's default workspace and the user's selected workspace are irrelevant.
    func guestURLContext(terminalID: String) -> TerminalLinkOpenRequest? {
        let id = SurfaceResourceID(machine: machine, kind: .terminal, key: terminalID)
        guard isRegisteredInCatalog(), !isFeatureSuspended,
              let projection = catalog.projections(of: id).sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString }).first,
              AppDelegate.shared?.workspaceFor(tabId: projection.workspaceID)?.panels[projection.panelID] != nil else { return nil }
        return TerminalLinkOpenRequest(rawValue: "", sourceWorkspaceId: projection.workspaceID,
                                      sourcePanelId: projection.panelID, workingDirectory: nil, focus: false)
    }

    var guestURLTerminals: [String] {
        catalog.snapshot.resources(on: machine).filter {
            $0.kind == .terminal && !catalog.projections(of: $0.id).isEmpty
        }.map { $0.id.key }
    }

    func configureGuestURLOpen(link: CloudMachineLink, socketPath: String) {
        if guestURLService == nil {
            guestURLService = CloudGuestURLService(machineID: machineID, executable: CloudTuiClientPaths.clientURL()) { [weak self] in
                self?.guestURLContext(terminalID: $0)
            }
        }
        guestURLService?.update(link: link, socketPath: socketPath, terminals: guestURLTerminals)
    }
}
