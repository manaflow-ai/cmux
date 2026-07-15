public import CmuxMobileShellModel
import Foundation

@MainActor
extension MobileShellComposite {
    /// Aggregate status for the workspace LIST chrome.
    ///
    /// `macConnectionStatus` describes the foreground RPC connection. After the
    /// user deletes that foreground computer, the remaining workspace rows can
    /// still belong to connected secondary Macs. In that state the list should
    /// not show a disconnected banner, because the visible workspace list is
    /// healthy even though the old foreground session was intentionally torn
    /// down.
    public var workspaceListConnectionStatus: MobileMacConnectionStatus {
        let foregroundKey: String?
        if let id = foregroundMacDeviceID, workspacesByMac[id] != nil {
            foregroundKey = id
        } else if workspacesByMac[Self.foregroundAnonymousKey] != nil {
            foregroundKey = Self.foregroundAnonymousKey
        } else {
            foregroundKey = nil
        }
        let visibleStatuses = workspacesByMac.compactMap { entry -> MobileMacConnectionStatus? in
            guard !entry.value.workspaces.isEmpty else { return nil }
            if entry.key == foregroundKey {
                return macConnectionStatus
            }
            return entry.value.status
        }
        if visibleStatuses.contains(.connected) {
            return .connected
        }
        if visibleStatuses.contains(.reconnecting) {
            return .reconnecting
        }
        return macConnectionStatus
    }

    /// UI-facing recover action for the workspace list when it is showing an
    /// offline/disconnected state. Pull-to-refresh and the offline status row's
    /// Reconnect button both call this.
    public func reconnectOrRefresh() async {
        if connectionState == .connected {
            await refreshWorkspaces()
            return
        }
        if workspaceListConnectionStatus == .connected {
            if let macDeviceID = workspaceListConnectedRefreshTargetMacDeviceID(),
               await switchToMac(macDeviceID: macDeviceID) {
                await refreshWorkspaces()
                return
            }
            await refreshSecondaryMacWorkspaces()
            return
        }
        if let macDeviceID = workspaceListReconnectTargetMacDeviceID(),
           await switchToMac(macDeviceID: macDeviceID) {
            return
        }
        _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
    }

    /// Pick a connected visible Mac for pull-to-refresh when the list is healthy
    /// but the foreground RPC slot is disconnected, e.g. after deleting the old
    /// foreground computer while secondary Mac rows remain visible.
    func workspaceListConnectedRefreshTargetMacDeviceID() -> String? {
        let connectionStatusesByMacDeviceID = macConnectionStatuses
        let pairedMacDeviceIDs = Set(pairedMacsForIdentityMatching.map(\.macDeviceID))

        func connectedMacDeviceID(from workspace: MobileWorkspacePreview?) -> String? {
            guard let workspace,
                  let macDeviceID = workspace.macDeviceID,
                  (workspace.macConnectionStatus ?? connectionStatusesByMacDeviceID[macDeviceID]) == .connected,
                  isReconnectableWorkspaceMacID(macDeviceID),
                  pairedMacDeviceIDs.contains(macDeviceID)
            else {
                return nil
            }
            return macDeviceID
        }

        if let selected = connectedMacDeviceID(from: explicitlySelectedWorkspace) {
            return selected
        }
        var candidates: [String] = []
        var seen: Set<String> = []
        for workspace in workspaces {
            guard let macDeviceID = connectedMacDeviceID(from: workspace),
                  !seen.contains(macDeviceID) else { continue }
            seen.insert(macDeviceID)
            candidates.append(macDeviceID)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// Pick the Mac a workspace-list recover gesture should reconnect.
    ///
    /// The banner's button and pull-to-refresh both enter through
    /// ``reconnectOrRefresh()``. When the list is disconnected but still shows
    /// workspace rows from a specific unavailable Mac, reconnect that visible
    /// owner first instead of blindly redialing whichever row is currently marked
    /// active in the paired-Mac store.
    func workspaceListReconnectTargetMacDeviceID() -> String? {
        let pairedMacDeviceIDs = Set(pairedMacsForIdentityMatching.map(\.macDeviceID))

        func reconnectableMacDeviceID(from workspace: MobileWorkspacePreview?) -> String? {
            guard let workspace,
                  (workspace.macConnectionStatus ?? macConnectionStatus) != .connected,
                  let macDeviceID = workspace.macDeviceID,
                  isReconnectableWorkspaceMacID(macDeviceID),
                  pairedMacDeviceIDs.contains(macDeviceID)
            else {
                return nil
            }
            return macDeviceID
        }

        if let selected = reconnectableMacDeviceID(from: explicitlySelectedWorkspace) {
            return selected
        }
        var candidates: [String] = []
        var seen: Set<String> = []
        for workspace in workspaces {
            guard let macDeviceID = reconnectableMacDeviceID(from: workspace),
                  !seen.contains(macDeviceID) else { continue }
            seen.insert(macDeviceID)
            candidates.append(macDeviceID)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func isReconnectableWorkspaceMacID(_ macDeviceID: String) -> Bool {
        !macDeviceID.isEmpty
            && macDeviceID != Self.foregroundAnonymousKey
            && !macDeviceID.hasPrefix("manual-")
    }
}
