internal import CmuxMobileDiagnostics
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
        // Discovery only yields Iroh-route candidates. Skip the broker
        // round-trip only when the app default AND every stored Computer's
        // per-pairing method is Tailscale — one Iroh Computer keeps it alive.
        guard !zeroTouchIrohDiscoveryDisabled,
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
        // Discovery only yields Iroh-route candidates. Skip the broker
        // round-trip only when the app default AND every stored Computer's
        // per-pairing method is Tailscale — one Iroh Computer keeps it alive.
        guard !zeroTouchIrohDiscoveryDisabled,
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

        // Admit discovered peers concurrently: each candidate is an
        // independent Mac, so one slow or unreachable peer must not delay the
        // others. The initial group width is the live-capacity headroom at
        // admission time; each dial re-checks capacity, scope, and foreground
        // health before it starts, and establishment re-checks the cap at
        // commit, so concurrent winners stay inside
        // `maximumLiveMacConnectionCount`.
        let admissionWidth = Self.maximumLiveMacConnectionCount
            - liveMacConnections.count
        MobileDebugLog.anchormux(
            "CMUX_CONNECT zero_touch_admission_start candidates=\(candidates.count) width=\(max(0, admissionWidth))"
        )
        let admissionResults = await withTaskGroup(
            of: SecondaryMacReconciliationResult.self,
            returning: [SecondaryMacReconciliationResult].self
        ) { group in
            var pending = candidates.makeIterator()
            var results: [SecondaryMacReconciliationResult] = []
            results.reserveCapacity(candidates.count)

            for _ in 0 ..< max(0, admissionWidth) {
                guard let candidate = pending.next() else { break }
                group.addTask { [weak self] in
                    guard let self else {
                        return SecondaryMacReconciliationResult(
                            macDeviceID: candidate.macDeviceID,
                            establishmentOutcome: nil
                        )
                    }
                    return await self.admitDiscoveredSecondaryIrohMac(
                        candidate,
                        scope: scope
                    )
                }
            }
            while let result = await group.next() {
                results.append(result)
                guard let candidate = pending.next() else { continue }
                group.addTask { [weak self] in
                    guard let self else {
                        return SecondaryMacReconciliationResult(
                            macDeviceID: candidate.macDeviceID,
                            establishmentOutcome: nil
                        )
                    }
                    return await self.admitDiscoveredSecondaryIrohMac(
                        candidate,
                        scope: scope
                    )
                }
            }
            return results
        }
        let attemptedCandidate = admissionResults.contains {
            $0.establishmentOutcome != nil
        }
        var transientFailureMacIDs: Set<String> = []
        for result in admissionResults
            where result.establishmentOutcome == .transientFailure {
            transientFailureMacIDs.insert(result.macDeviceID)
        }
        MobileDebugLog.anchormux(
            "CMUX_CONNECT zero_touch_admission_end attempted=\(admissionResults.count(where: { $0.establishmentOutcome != nil })) transient=\(transientFailureMacIDs.count)"
        )
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

    /// One bounded zero-touch admission dial. Re-checks live capacity, scope,
    /// and foreground health immediately before dialing so a concurrent winner
    /// (foreground attach, warm-pool dial, or another admission) stops a
    /// queued candidate instead of oversubscribing the pool. A `nil` outcome
    /// means the dial never started.
    private func admitDiscoveredSecondaryIrohMac(
        _ candidate: MobilePairedMac,
        scope: MobileShellScopeSnapshot
    ) async -> SecondaryMacReconciliationResult {
        guard liveMacConnections.count < Self.maximumLiveMacConnectionCount,
              await isScopeCurrent(scope),
              connectionState == .connected,
              remoteClient != nil else {
            MobileDebugLog.anchormux(
                "CMUX_CONNECT secondary_admission_skipped mac=\(candidate.macDeviceID.prefix(8)) tag=\(candidate.instanceTag ?? "-")"
            )
            return SecondaryMacReconciliationResult(
                macDeviceID: candidate.macDeviceID,
                establishmentOutcome: nil
            )
        }
        let outcome = await establishSecondaryMacSubscription(
            for: candidate,
            scope: scope,
            authorityValidation: .store,
            persistAuthenticatedDiscovery: true
        )
        return SecondaryMacReconciliationResult(
            macDeviceID: candidate.macDeviceID,
            establishmentOutcome: outcome
        )
    }
}
