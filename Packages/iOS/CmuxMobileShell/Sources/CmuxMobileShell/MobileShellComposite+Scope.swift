import Foundation
import CmuxMobilePairedMac

@MainActor
extension MobileShellComposite {
    /// Capture the current signed-in account/team scope for async list loads and
    /// route writes.
    func currentScopeSnapshot(userID explicitUserID: String? = nil) async -> MobileShellScopeSnapshot? {
        guard isSignedIn,
              let userID = explicitUserID ?? identityProvider?.currentUserID,
              !userID.isEmpty else {
            return nil
        }
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != userID {
            return nil
        }
        return MobileShellScopeSnapshot(
            userID: userID,
            teamID: await teamIDProvider(),
            generation: secondaryAggregationScopeGeneration
        )
    }

    func pairedMacScopeKey(_ scope: MobileShellScopeSnapshot) -> String {
        makePairedMacScopeKey(userID: scope.userID, teamID: scope.teamID)
    }

    func makePairedMacScopeKey(userID: String, teamID: String?) -> String {
        "\(userID)\t\(teamID ?? "")"
    }

    func userWideScope(from scope: MobileShellScopeSnapshot) -> MobileShellScopeSnapshot {
        MobileShellScopeSnapshot(userID: scope.userID, teamID: nil, generation: scope.generation)
    }

    /// Whether a previously-captured list-load scope is still current.
    func isScopeCurrent(_ scope: MobileShellScopeSnapshot) async -> Bool {
        guard isSignedIn,
              secondaryAggregationScopeGeneration == scope.generation else {
            return false
        }
        if let currentUserID = identityProvider?.currentUserID,
           currentUserID != scope.userID {
            return false
        }
        return await teamIDProvider() == scope.teamID
    }

    func resumePresenceFirstDataWaiter(id: UUID) {
        presenceFirstDataWaiters.removeValue(forKey: id)?.resume()
    }

    func resumeAllPresenceFirstDataWaiters() {
        for id in Array(presenceFirstDataWaiters.keys) {
            resumePresenceFirstDataWaiter(id: id)
        }
    }

    /// Waits (bounded) until any presence data has been applied. The scoped-dev
    /// reconnect gates on this: saved-Mac build identities come from presence,
    /// so a cold-launch reconnect that outruns the first snapshot would see
    /// every identity as unknown-allowed and could dial another tag's dev Mac
    /// - the exact cross-tag attach the scope policy exists to stop. On timeout
    /// (presence down/slow) the reconnect proceeds with unknown identities,
    /// which is the pre-policy behavior, kept so presence outages never block
    /// reconnect entirely.
    func awaitFirstPresenceData(upTo limit: Duration) async {
        if !presenceMap.isEmpty { return }
        let id = UUID()
        let deadline = Task { [weak self] in
            try? await ContinuousClock().sleep(for: limit)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.resumePresenceFirstDataWaiter(id: id) }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            presenceFirstDataWaiters[id] = continuation
        }
        deadline.cancel()
    }

    /// The build-scope verdict for auto-connecting to this saved Mac, per
    /// ``MobileSavedMacScopePolicy``: a tagged dev phone must not dial OTHER
    /// tags' dev Macs (each tagged build is an isolated identity; dialing them
    /// attached this phone to other agents' instances).
    func savedMacScopeDecision(_ mac: MobilePairedMac) -> MobileSavedMacScopePolicy.Decision {
        // RAW per-device presence, never the alias rollup (`presenceSummary(for:)`):
        // aliases coalesce saved records that share a dial endpoint, so a rolled-up
        // summary could substitute a SIBLING tagged build's identity for this row -
        // refusing the matching Mac or admitting the wrong one. Each tagged Mac app
        // heartbeats under its own device UUID, so the per-deviceId summary is the
        // exact identity of the row being filtered.
        let summary = presenceMap.deviceSummary(deviceId: mac.macDeviceID)
        return MobileSavedMacScopePolicy().decision(
            macDevTag: summary?.tag,
            macBundleID: summary?.bundleId,
            iosScope: iosBuildScope
        )
    }

    /// Writes the persisted paired-Mac hint only when `generation` is still the
    /// current reconnect attempt, so a superseded attempt can't clobber a newer
    /// attempt's determination.
    func setHasKnownPairedMac(_ value: Bool, generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        hasKnownPairedMac = value
    }

    /// Mark the stored-Mac reconnect attempt resolved without a live connection,
    /// but only when `generation` is still current.
    ///
    /// Clears ``isReconnectingStoredMac`` and sets
    /// ``didFinishStoredMacReconnectAttempt`` so the root scene falls through to
    /// the disconnected/add-device view instead of spinning on the restoring UI.
    /// A superseded attempt (older `generation`) is a no-op so it can't resolve the
    /// gate while a newer reconnect is in progress.
    func finishStoredMacReconnectAttempt(generation: Int) {
        guard generation == storedMacReconnectGeneration else { return }
        isReconnectingStoredMac = false
        didFinishStoredMacReconnectAttempt = true
    }
}
