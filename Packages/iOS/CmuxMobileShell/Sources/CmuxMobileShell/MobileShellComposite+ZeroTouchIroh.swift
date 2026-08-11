import CmuxMobilePairedMac
import Foundation

private enum ZeroTouchSecondaryAuthenticationOutcome {
    case persisted
    case transientFailure
    case discarded
    case superseded
}

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
        guard let personalIrohDiscovery else { return [] }
        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard generation == storedMacReconnectGeneration,
              await isScopeCurrent(scope) else { return [] }

        var seen = pairingIDs
        var candidates: [MobilePairedMac] = []
        for mac in discovered {
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: mac.deviceID,
                instanceTag: mac.instanceTag
            )
            guard !mac.routes.isEmpty,
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

    /// Retains every discovered app instance except the foreground winner.
    /// Broker data is only a dial hint; each row still has to prove its device
    /// and build identity over an authenticated RPC before it is persisted.
    func stageZeroTouchIrohCandidatesForSecondaryAuthentication(
        _ candidates: [MobilePairedMac],
        scope: MobileShellScopeSnapshot
    ) {
        guard multiMacAggregationEnabled else { return }
        if pendingZeroTouchIrohCandidateScope != scope {
            pendingZeroTouchIrohCandidatesByPairingID = [:]
            pendingZeroTouchIrohCandidateScope = scope
        }
        let foregroundPairingID = foregroundMacDeviceID.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0,
                instanceTag: activeMacInstanceTag
            )
        }
        for candidate in candidates where candidate.id != foregroundPairingID {
            pendingZeroTouchIrohCandidatesByPairingID[candidate.id] = candidate
        }
        if pendingZeroTouchIrohCandidatesByPairingID.isEmpty {
            pendingZeroTouchIrohCandidateScope = nil
        }
    }

    /// Authenticates and saves sibling zero-touch candidates without replacing
    /// the foreground connection. Successful rows become ordinary secondary
    /// aggregation targets on the same pass.
    func authenticatePendingZeroTouchIrohCandidates(
        scope: MobileShellScopeSnapshot
    ) async {
        guard let pairedMacStore,
              pendingZeroTouchIrohCandidateScope == scope,
              !pendingZeroTouchIrohCandidatesByPairingID.isEmpty else {
            return
        }
        let storedPairingIDs = Set(
            (try? await pairedMacStore.loadAll(
                stackUserID: scope.userID,
                teamID: scope.teamID
            ))?.map(\.id) ?? []
        )
        guard !Task.isCancelled, await isScopeCurrent(scope) else { return }

        var didPersistCandidate = false
        var transientFailureMacIDs: Set<String> = []
        let foregroundPairingID = foregroundMacDeviceID.map {
            MobilePairedMac.pairingID(
                macDeviceID: $0,
                instanceTag: activeMacInstanceTag
            )
        }
        let candidates = pendingZeroTouchIrohCandidatesByPairingID.values
            .sorted {
                if $0.lastSeenAt != $1.lastSeenAt {
                    return $0.lastSeenAt > $1.lastSeenAt
                }
                return $0.id < $1.id
            }
        candidateLoop: for candidate in candidates {
            guard !Task.isCancelled, await isScopeCurrent(scope) else {
                break candidateLoop
            }
            guard pendingZeroTouchIrohCandidatesByPairingID[candidate.id]
                    == candidate else {
                continue
            }
            switch await authenticateZeroTouchIrohCandidate(
                candidate,
                storedPairingIDs: storedPairingIDs,
                foregroundPairingID: foregroundPairingID,
                scope: scope
            ) {
            case .persisted:
                didPersistCandidate = true
                pendingZeroTouchIrohCandidatesByPairingID[candidate.id] = nil
            case .discarded:
                pendingZeroTouchIrohCandidatesByPairingID[candidate.id] = nil
            case .transientFailure:
                transientFailureMacIDs.insert(
                    candidate.macDeviceID
                )
            case .superseded:
                break candidateLoop
            }
        }
        if pendingZeroTouchIrohCandidatesByPairingID.isEmpty {
            pendingZeroTouchIrohCandidateScope = nil
        }
        if didPersistCandidate {
            await loadPairedMacs()
        }
        if !transientFailureMacIDs.isEmpty {
            scheduleSecondaryAggregationRetry(
                macDeviceIDs: transientFailureMacIDs
            )
        }
    }

    private func authenticateZeroTouchIrohCandidate(
        _ candidate: MobilePairedMac,
        storedPairingIDs: Set<String>,
        foregroundPairingID: String?,
        scope: MobileShellScopeSnapshot
    ) async -> ZeroTouchSecondaryAuthenticationOutcome {
        guard !storedPairingIDs.contains(candidate.id),
              candidate.id != foregroundPairingID,
              await !isHiddenMacDeviceID(
                  candidate.macDeviceID,
                  instanceTag: candidate.instanceTag,
                  scope: scope
              ) else {
            return .discarded
        }
        let handle: SecondaryClientHandle
        switch await makeSecondaryClient(for: candidate) {
        case let .connected(connectedHandle):
            handle = connectedHandle
        case .transientFailure:
            return .transientFailure
        case .permanentFailure:
            return .discarded
        }
        let client = handle.client
        guard !Task.isCancelled, await isScopeCurrent(scope) else {
            await client.disconnect()
            return .superseded
        }
        guard macBuildIsCompatible(
            instanceTag: handle.authenticatedInstanceTag
        ),
              await !isHiddenMacDeviceID(
                  candidate.macDeviceID,
                  instanceTag: candidate.instanceTag,
                  scope: scope
              ) else {
            await client.disconnect()
            return .discarded
        }
        let accepted = await persistPairedMacFromTicket(
            handle.ticket,
            instanceTagUpdate: .replace(handle.authenticatedInstanceTag),
            displayNameOverride: handle.authenticatedDisplayName,
            markActive: false,
            ifStillCurrent: { [weak self] in
                self?.pendingZeroTouchIrohCandidateScope == scope
            }
        )
        await client.disconnect()
        guard !Task.isCancelled, await isScopeCurrent(scope) else {
            return .superseded
        }
        return accepted ? .persisted : .transientFailure
    }
}
