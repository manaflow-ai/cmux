import CmuxMobilePairedMac
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
        if pairedMacs.isEmpty, hasHiddenComputers {
            // Hidden Macs have no reconnectable row or workspace target. Present
            // the normal shell as an ordinary empty list instead of advertising a
            // reconnect action that cannot reach anything visible.
            return .connected
        }
        let foregroundKey: MacPairingKey?
        if foregroundMacDeviceID != nil, workspacesByMac[foregroundMacKey] != nil {
            foregroundKey = foregroundMacKey
        } else if workspacesByMac[.anonymousForeground] != nil {
            foregroundKey = .anonymousForeground
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

    /// Whether the app currently holds a live serving path to a Mac: an
    /// established control session, or a terminal lane still delivering
    /// output. The recovery flags describe only the CONTROL session, so on
    /// their own they can flip the list chrome to "Not Connected" while
    /// terminal lanes keep streaming (observed for hours on hardware). The
    /// chrome consults this signal to render at worst "Reconnecting…" while
    /// anything is demonstrably serving.
    public var workspaceListHasLiveTransportPath: Bool {
        connectionState == .connected
            || !terminalLaneOutputReadySurfaceIDs.isEmpty
    }

    /// UI reconnect entry for a specific workspace's Mac (status pill, toast
    /// Reconnect action). Unlike ``reconnectOrRefresh()``, which gates on the
    /// AGGREGATE ``workspaceListConnectionStatus`` (a healthy secondary Mac
    /// makes it refresh or switch elsewhere), this redials the supplied Mac
    /// directly when it is the unavailable foreground target.
    public func reconnectToMac(
        macDeviceID: String?,
        instanceTag: String? = nil
    ) async {
        // A nil/empty target means the caller is showing the foreground
        // connection's status (anonymous foreground, or no selected
        // workspace), so the action must redial the foreground too — not the
        // aggregate recovery, which a healthy secondary Mac would divert.
        let targetMacDeviceID = (macDeviceID?.isEmpty == false) ? macDeviceID : nil
        // Include the retained recovery target: automatic recovery nils
        // foregroundMacDeviceID, and retrying that same Mac must take the
        // foreground-redial branch below (whose teardown preserves secondary
        // state), not the cross-Mac switch whose failure cleanup does not.
        let foregroundTargetMacDeviceID = foregroundMacDeviceID ?? recoveryTargetMacDeviceID
        // The target is "already foreground" only as an exact PAIRING: a
        // sibling build of the foreground's own physical Mac still needs a
        // real switch, not a foreground refresh of the other build.
        let targetsForegroundPairing = targetMacDeviceID == foregroundTargetMacDeviceID
            && (instanceTag == nil
                || macInstanceTagAuthority.sameStoredAuthority(
                    instanceTag,
                    activeMacInstanceTag
                ))
        if let targetMacDeviceID, !targetsForegroundPairing {
            if await switchToMac(
                macDeviceID: targetMacDeviceID,
                instanceTag: instanceTag
            ) {
                return
            }
            await reconnectOrRefresh()
            return
        }
        if connectionState == .connected, macConnectionStatus == .connected {
            // Defensive: the target is healthy, don't tear down a live
            // connection for a stray reconnect gesture.
            await refreshWorkspaces()
            return
        }
        // Explicit user gesture: bypass the automatic-retry cooldown, mirror
        // of the disconnected branch in reconnectOrRefresh().
        if let accountID = identityProvider?.currentUserID {
            clearTransientAutomaticReconnectBackoff(accountID: accountID)
        }
        if connectionState == .connected {
            // The live event stream can fail before the RPC client's
            // transport closes. Tear down the stale client so switchToMac
            // cannot take its already-connected fast path and skip the dial,
            // but keep secondary-Mac subscriptions and workspaces: this
            // branch is reached exactly when a secondary may be healthy, and
            // a failed foreground redial must not strand them.
            disconnectLiveConnection(preservingOtherMacWorkspaceState: true)
        }
        if let targetMacDeviceID, await switchToMac(
            macDeviceID: targetMacDeviceID,
            instanceTag: instanceTag
        ) {
            return
        }
        if await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID) {
            return
        }
        // Failed dials run their own cleanup with the default non-preserving
        // teardown, cancelling the secondary subscriptions preserved above
        // (their last-known rows stay, downgraded to unavailable). Rebuild the
        // subscriptions so a failed foreground redial cannot strand healthy
        // secondary Macs on stale rows.
        await refreshSecondaryMacWorkspaces()
    }

    /// UI-facing recover action for the workspace list when it is showing an
    /// offline/disconnected state. Pull-to-refresh and the offline status row's
    /// Reconnect button both call this.
    public func reconnectOrRefresh() async {
        let diagnosticStartedAt = appDiagnosticNow()
        let diagnosticCorrelationID = foregroundMacDeviceID
        recordAppEvent(
            .workspaceListRecoveryStarted,
            correlationID: diagnosticCorrelationID
        )
        defer {
            let succeeded = workspaceListConnectionStatus == .connected
            recordAppEvent(
                succeeded ? .workspaceListRecoverySucceeded : .workspaceListRecoveryFailed,
                correlationID: diagnosticCorrelationID,
                startedAt: diagnosticStartedAt,
                failure: succeeded ? nil : (Task.isCancelled ? .cancelled : .connectionClosed),
                count: succeeded ? workspaces.count : nil
            )
        }
        let listStatus = workspaceListConnectionStatus
        if connectionState == .connected, listStatus == .connected {
            await refreshWorkspaces()
            return
        }
        if listStatus == .connected {
            if let target = workspaceListConnectedRefreshTarget(),
               await switchToMac(
                   macDeviceID: target.macDeviceID,
                   instanceTag: target.instanceTag
               ) {
                await refreshWorkspaces()
                return
            }
            await refreshSecondaryMacWorkspaces()
            return
        }
        let reconnectTarget = workspaceListReconnectTarget()
        // This is the user's explicit Reconnect/pull gesture: like
        // `recoverMobileConnection(trigger: .manual)`, it must bypass the
        // automatic-retry cooldown. Without this, a transient backoff recorded
        // by a failed (or deadline-abandoned) automatic attempt silently
        // swallows the user's tap and the dial never happens.
        if let accountID = identityProvider?.currentUserID {
            clearTransientAutomaticReconnectBackoff(accountID: accountID)
        }
        if connectionState == .connected {
            // The live event stream can fail before the RPC client's transport
            // closes. In that state the workspace list correctly renders the
            // unavailable banner, but `connectionState` still says connected.
            // Tear down that stale client so `switchToMac` cannot take its
            // already-connected fast path and skip the user's explicit redial.
            disconnectLiveConnection()
        }
        if let reconnectTarget,
           await switchToMac(
               macDeviceID: reconnectTarget.macDeviceID,
               instanceTag: reconnectTarget.instanceTag
           ) {
            return
        }
        _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
    }

    /// Pick a connected visible Mac for pull-to-refresh when the list is healthy
    /// but the foreground RPC slot is disconnected, e.g. after deleting the old
    /// foreground computer while secondary Mac rows remain visible.
    func workspaceListConnectedRefreshTargetMacDeviceID() -> String? {
        workspaceListConnectedRefreshTarget()?.macDeviceID
    }

    /// Pairing-exact variant: rows carry their build's tag, and sibling builds
    /// of one Mac are distinct targets, so ambiguity fails closed.
    func workspaceListConnectedRefreshTarget() -> (macDeviceID: String, instanceTag: String?)? {
        let connectionStatusesByPairingID = macConnectionStatuses
        let pairedMacPairingIDs = Set(pairedMacsForIdentityMatching.map(\.id))

        func connectedTarget(
            from workspace: MobileWorkspacePreview?
        ) -> (macDeviceID: String, instanceTag: String?)? {
            guard let workspace, let macDeviceID = workspace.macDeviceID else {
                return nil
            }
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            guard (workspace.macConnectionStatus
                ?? connectionStatusesByPairingID[pairingID]) == .connected,
                  isReconnectableWorkspaceMacID(macDeviceID),
                  pairedMacPairingIDs.contains(pairingID) else {
                return nil
            }
            return (macDeviceID, workspace.macInstanceTag)
        }

        if let selected = connectedTarget(from: explicitlySelectedWorkspace) {
            return selected
        }
        var candidates: [(macDeviceID: String, instanceTag: String?)] = []
        var seen: Set<MacPairingKey> = []
        for workspace in workspaces {
            guard let target = connectedTarget(from: workspace) else { continue }
            let key = MacPairingKey(
                macDeviceID: target.macDeviceID,
                instanceTag: target.instanceTag
            )
            guard seen.insert(key).inserted else { continue }
            candidates.append(target)
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
        workspaceListReconnectTarget()?.macDeviceID
    }

    /// The exact pairing a list-level Reconnect should dial: rows carry their
    /// build's instance tag, and sibling builds of one Mac are distinct
    /// targets, so ambiguity across pairings fails closed.
    func workspaceListReconnectTarget() -> (macDeviceID: String, instanceTag: String?)? {
        let pairedMacPairingIDs = Set(pairedMacsForIdentityMatching.map(\.id))

        func reconnectableTarget(
            from workspace: MobileWorkspacePreview?
        ) -> (macDeviceID: String, instanceTag: String?)? {
            guard let workspace,
                  let macDeviceID = workspace.macDeviceID else {
                return nil
            }
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: macDeviceID,
                instanceTag: workspace.macInstanceTag
            )
            guard (workspace.macConnectionStatus
                ?? macConnectionStatuses[pairingID]
                ?? (matchesForegroundPairing(
                    macDeviceID: macDeviceID,
                    instanceTag: workspace.macInstanceTag
                ) ? macConnectionStatus : nil)) != .connected,
                  isReconnectableWorkspaceMacID(macDeviceID),
                  pairedMacPairingIDs.contains(pairingID) else {
                return nil
            }
            return (macDeviceID, workspace.macInstanceTag)
        }

        if let selected = reconnectableTarget(from: explicitlySelectedWorkspace) {
            return selected
        }
        var candidates: [(macDeviceID: String, instanceTag: String?)] = []
        var seen: Set<MacPairingKey> = []
        for workspace in workspaces {
            guard let target = reconnectableTarget(from: workspace) else { continue }
            let key = MacPairingKey(
                macDeviceID: target.macDeviceID,
                instanceTag: target.instanceTag
            )
            guard seen.insert(key).inserted else { continue }
            candidates.append(target)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func isReconnectableWorkspaceMacID(_ macDeviceID: String) -> Bool {
        !macDeviceID.isEmpty
            && macDeviceID != Self.foregroundAnonymousKey
            && !macDeviceID.hasPrefix("manual-")
    }
}
