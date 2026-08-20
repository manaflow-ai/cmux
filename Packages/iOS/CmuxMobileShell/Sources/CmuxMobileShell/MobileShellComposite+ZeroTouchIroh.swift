import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Limits one automatic launch pass so stale live registrations cannot make
    /// the restoring state scale with an account's full development fleet.
    static let maximumAutomaticIrohCandidateCount = 4

    /// Loads first-pair candidates from the current authenticated broker view.
    ///
    /// These transient rows are never written here. ``connectStoredMac`` still
    /// requires Iroh admission and authenticated host status, and its guarded
    /// persistence path writes only the device/tag the Mac proves after connect.
    func discoverZeroTouchIrohCandidates(
        scope: MobileShellScopeSnapshot,
        generation: Int,
        excluding pairingIDs: Set<String>
    ) async -> [MobilePairedMac] {
        // Discovery only yields Iroh-route candidates, which the Tailscale
        // connection method can never dial; skip the broker round-trip.
        guard connectionMethodStore?.method != .tailscale,
              let personalIrohDiscovery else { return [] }
        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard generation == storedMacReconnectGeneration,
              await isScopeCurrent(scope) else { return [] }

        return await zeroTouchIrohCandidates(
            from: discovered,
            scope: scope,
            excluding: pairingIDs
        )
    }

    /// Loads fresh compatible peers after the foreground session is usable.
    ///
    /// Unlike launch restoration, this path never competes for focus. The
    /// caller authenticates each transient candidate as a bounded control peer
    /// before the row is persisted.
    func discoverSecondaryZeroTouchIrohCandidates(
        scope: MobileShellScopeSnapshot,
        excluding pairingIDs: Set<String>
    ) async -> [MobilePairedMac] {
        // Discovery only yields Iroh-route candidates, which the Tailscale
        // connection method can never dial; skip the broker round-trip.
        guard connectionMethodStore?.method != .tailscale,
              let personalIrohDiscovery else { return [] }
        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { return [] }

        return await zeroTouchIrohCandidates(
            from: discovered,
            scope: scope,
            excluding: pairingIDs
        )
    }

    private func zeroTouchIrohCandidates(
        from discovered: [MobileDiscoveredIrohMac],
        scope: MobileShellScopeSnapshot,
        excluding pairingIDs: Set<String>
    ) async -> [MobilePairedMac] {
        var seen = pairingIDs
        var candidates: [MobilePairedMac] = []
        for mac in discovered {
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: mac.deviceID,
                instanceTag: mac.instanceTag
            )
            guard macBuildIsCompatible(instanceTag: mac.instanceTag),
                  !mac.routes.isEmpty,
                  mac.routes.allSatisfy({ $0.kind == .iroh }),
                  await !isHiddenMacDeviceID(
                      mac.deviceID,
                      instanceTag: mac.instanceTag,
                      scope: scope
                  ) else { continue }
            guard seen.insert(pairingID).inserted else { continue }
            candidates.append(MobilePairedMac(
                macDeviceID: mac.deviceID,
                displayName: mac.displayName,
                routes: mac.routes,
                createdAt: mac.lastSeenAt,
                lastSeenAt: mac.lastSeenAt,
                isActive: false,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                instanceTag: mac.instanceTag
            ))
            if candidates.count == Self.maximumAutomaticIrohCandidateCount {
                break
            }
        }
        return candidates
    }

    /// Authenticates fresh compatible peers as control sessions after focus is
    /// established. Successful admission persists an exact device/tag row but
    /// never changes the user's active Mac.
    func establishDiscoveredSecondaryIrohMacs(
        scope: MobileShellScopeSnapshot,
        excluding storedMacs: [MobilePairedMac]
    ) async {
        guard connectionState == .connected,
              remoteClient != nil,
              liveMacConnections.count < Self.maximumLiveMacConnectionCount
        else { return }

        var excludedPairingIDs = Set(storedMacs.map(\.id))
        excludedPairingIDs.formUnion(
            secondaryMacSubscriptions.keys.map(\.pairingID)
        )
        if let foregroundMacDeviceID {
            excludedPairingIDs.insert(MobilePairedMac.pairingID(
                macDeviceID: foregroundMacDeviceID,
                instanceTag: activeMacInstanceTag
            ))
        }
        let candidates = await discoverSecondaryZeroTouchIrohCandidates(
            scope: scope,
            excluding: excludedPairingIDs
        )
        guard await isScopeCurrent(scope),
              connectionState == .connected,
              remoteClient != nil else { return }

        var attemptedCandidate = false
        var transientFailureMacIDs: Set<String> = []
        for candidate in candidates {
            guard liveMacConnections.count
                    < Self.maximumLiveMacConnectionCount,
                  await isScopeCurrent(scope),
                  connectionState == .connected,
                  remoteClient != nil else { break }
            attemptedCandidate = true
            switch await establishSecondaryMacSubscription(
                for: candidate,
                scope: scope,
                authorityValidation: .store,
                persistAuthenticatedDiscovery: true
            ) {
            case .connected, .permanentFailure, .superseded:
                break
            case .transientFailure:
                transientFailureMacIDs.insert(candidate.macDeviceID)
            }
        }
        guard attemptedCandidate, await isScopeCurrent(scope) else { return }
        // Some authenticated rows can persist even if their first workspace
        // snapshot fails. Reload once after the bounded pass so every proven
        // peer appears immediately with its accurate availability state.
        await loadPairedMacs()
        if !transientFailureMacIDs.isEmpty {
            // These candidates are not persisted until authentication succeeds,
            // so the normal stored-row retry cannot find them. Preserve the
            // discovery intent and let the same backoff rerun broker discovery.
            preserveSecondaryIrohDiscoveryIntent()
            scheduleSecondaryAggregationRetry(
                macDeviceIDs: transientFailureMacIDs,
                needsFullRefresh: true
            )
        }
    }
}
