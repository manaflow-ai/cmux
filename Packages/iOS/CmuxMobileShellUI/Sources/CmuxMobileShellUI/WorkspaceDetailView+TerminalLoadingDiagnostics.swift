#if os(iOS)
import CMUXMobileCore
import CmuxMobileShellModel

extension WorkspaceDetailView {
    var loadingDiagnosticsConnectionStatus: MobileMacConnectionStatus {
        if let macDeviceID = workspace.macDeviceID,
           !macDeviceID.isEmpty,
           !loadingDiagnosticsMatchesForegroundMac(macDeviceID) {
            return .unavailable
        }
        return workspace.macConnectionStatus ?? connectionStatus
    }

    var loadingDiagnosticsStoredRouteDescription: String? {
        guard let macDeviceID = workspace.macDeviceID,
              !macDeviceID.isEmpty else {
            return nil
        }
        return store.displayPairedMacs
            .first { mac in
                mac.macDeviceID == macDeviceID || store.pairedMacAliasIDs(for: mac.macDeviceID).contains(macDeviceID)
            }
            .flatMap { CmxAttachRoute.deviceTreeRouteDescription(for: $0.routes) }
    }

    var activeLoadingDiagnosticsRoute: CmxAttachRoute? {
        guard let macDeviceID = workspace.macDeviceID,
              !macDeviceID.isEmpty else {
            return loadingDiagnosticsConnectionStatus == .connected ? store.activeRoute : nil
        }
        if loadingDiagnosticsMatchesForegroundMac(macDeviceID) {
            return store.activeRoute
        }
        return nil
    }

    var loadingDiagnosticsConnectionError: String? {
        loadingDiagnosticsMatchesForegroundMac(workspace.macDeviceID) ? store.connectionError : nil
    }

    var loadingDiagnosticsConnectionErrorGuidance: String? {
        loadingDiagnosticsMatchesForegroundMac(workspace.macDeviceID) ? store.connectionErrorGuidance : nil
    }

    func refreshLoadingDiagnosticsConnection() {
        Task {
            if let macDeviceID = workspace.macDeviceID,
               !macDeviceID.isEmpty {
                _ = await store.switchToMac(macDeviceID: macDeviceID)
            }
            await store.reconnectOrRefresh()
        }
    }

    private func loadingDiagnosticsMatchesForegroundMac(_ macDeviceID: String?) -> Bool {
        guard let macDeviceID,
              !macDeviceID.isEmpty else {
            return false
        }
        if macDeviceID == store.connectedMacDeviceID {
            return true
        }
        if macDeviceID == store.activeTicket?.macDeviceID {
            return true
        }
        guard let connectedMacDeviceID = store.connectedMacDeviceID,
              store.pairedMacAliasIDs(for: macDeviceID).contains(connectedMacDeviceID) else {
            return false
        }
        return true
    }
}
#endif
