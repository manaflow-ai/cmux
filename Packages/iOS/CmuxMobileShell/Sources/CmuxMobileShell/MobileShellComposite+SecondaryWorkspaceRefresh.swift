internal import CmuxMobileRPC
internal import CmuxMobileShellModel
internal import Foundation
internal import OSLog

private let secondaryWorkspaceRefreshLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

extension MobileShellComposite {
    /// Fetch one Mac's workspace list over an existing client while preserving
    /// focus events that arrived after the request began.
    func fetchSecondaryWorkspaces(
        on client: MobileCoreRPCClient,
        macDeviceID: String
    ) async -> [MobileWorkspacePreview]? {
        guard let runtime else { return nil }
        let focusRevision = workspaceFocusRevisionSnapshot()
        do {
            let requestData = try MobileCoreRPCClient.requestData(method: "workspace.list", params: [:])
            let resultData = try await client.sendRequest(
                requestData,
                timeoutNanoseconds: runtime.pairingRequestTimeoutNanoseconds
            )
            let response = try MobileSyncWorkspaceListResponse.decode(resultData)
            return response.workspaces.map { remote in
                var workspace = MobileWorkspacePreview(remote: remote)
                workspace.macDeviceID = macDeviceID
                if let existingWorkspace = workspaces.first(where: {
                    $0.rpcWorkspaceID == workspace.rpcWorkspaceID
                        && $0.macDeviceID == macDeviceID
                }) {
                    preserveNewerWorkspaceFocusIfNeeded(
                        in: &workspace,
                        from: existingWorkspace,
                        macID: macDeviceID,
                        listStartedAtFocusRevision: focusRevision
                    )
                }
                return workspace
            }
        } catch {
            secondaryWorkspaceRefreshLog.warning(
                "secondary workspace fetch failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    func foregroundWorkspaceRowIDs() -> Set<MobileWorkspacePreview.ID> {
        let stateKey: String
        if let foregroundMacDeviceID, workspacesByMac[foregroundMacDeviceID] != nil {
            stateKey = foregroundMacDeviceID
        } else {
            stateKey = Self.foregroundAnonymousKey
        }
        guard let state = workspacesByMac[stateKey] else { return [] }
        return Set(state.workspaces.compactMap { stateWorkspace in
            workspaces.first { workspace in
                workspace.rpcWorkspaceID == stateWorkspace.rpcWorkspaceID
                    && (stateKey == Self.foregroundAnonymousKey
                        ? workspace.macDeviceID == nil
                        : workspace.macDeviceID == stateKey)
            }?.id
        })
    }

    func workspaceRowIDs(
        ownedByMacDeviceID macDeviceID: String?
    ) -> Set<MobileWorkspacePreview.ID> {
        Set(workspaces.compactMap { workspace in
            if let macDeviceID, !macDeviceID.isEmpty {
                return workspace.macDeviceID == macDeviceID ? workspace.id : nil
            }
            return workspace.macDeviceID == nil ? workspace.id : nil
        })
    }

    /// Installs a full secondary-Mac list and reconciles hierarchy recovery for
    /// both surviving and remotely removed workspace rows.
    func installAuthoritativeSecondaryWorkspaceState(
        macID: String,
        displayName: String?,
        workspaces: [MobileWorkspacePreview],
        actionCapabilities: MobileWorkspaceActionCapabilities
    ) {
        let previousWorkspaceIDs = workspaceRowIDs(ownedByMacDeviceID: macID)
        workspacesByMac[macID] = MacWorkspaceState(
            macDeviceID: macID,
            displayName: displayName,
            workspaces: workspaces,
            status: .connected,
            actionCapabilities: actionCapabilities
        )
        terminalReorderGate.reconcileAfterAuthoritativeRefresh(
            workspaceIDs: previousWorkspaceIDs.union(
                workspaceRowIDs(ownedByMacDeviceID: macID)
            )
        )
        pruneWorkspaceFocusRevisions(
            macID: macID,
            retainingRemoteWorkspaceIDs: Set(workspaces.map { $0.rpcWorkspaceID.rawValue })
        )
    }

    /// Coalesced full-list refresh for a secondary Mac driven by
    /// `workspace.updated` pushes. Each task performs at most one leading and
    /// one trailing pass, then hands any newer request to a fresh bounded task.
    func scheduleSecondaryRefresh(
        macID: String,
        client: MobileCoreRPCClient,
        displayName: String?
    ) {
        guard let subscription = secondaryMacSubscriptions[macID],
              subscription.client === client else { return }
        guard subscription.refreshTask == nil else {
            subscription.refreshPending = true
            return
        }
        subscription.refreshTask = Task { @MainActor [weak self, weak subscription] in
            guard let self, let subscription else { return }
            for _ in 0..<2 {
                subscription.refreshPending = false
                subscription.refreshStartedGeneration &+= 1
                let generation = subscription.refreshStartedGeneration
                let previews = await self.fetchSecondaryWorkspaces(
                    on: client,
                    macDeviceID: macID
                )
                guard self.secondaryMacSubscriptions[macID] === subscription else { return }
                subscription.refreshFinishedGeneration = generation
                if let previews {
                    subscription.refreshCompletedGeneration = generation
                    self.installAuthoritativeSecondaryWorkspaceState(
                        macID: macID,
                        displayName: displayName,
                        workspaces: previews,
                        actionCapabilities: subscription.actionCapabilities
                    )
                }
                guard subscription.refreshPending else { break }
            }
            guard self.secondaryMacSubscriptions[macID] === subscription else { return }
            let needsFollowUp = subscription.refreshPending
            subscription.refreshTask = nil
            if needsFollowUp {
                self.scheduleSecondaryRefresh(
                    macID: macID,
                    client: client,
                    displayName: displayName
                )
            }
        }
    }
}
