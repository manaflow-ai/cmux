import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

extension MobileShellComposite {
    /// Snapshot the authenticated foreground route before a destructive switch.
    /// The saved row may already describe another tagged process on the same
    /// physical Mac, so rollback must use live A rather than persisted B.
    func liveForegroundMacForSwitchRestore() -> MobilePairedMac? {
        guard hasActiveMacConnection,
              let macDeviceID = foregroundMacDeviceID,
              !macDeviceID.isEmpty else { return nil }
        var routes = activeTicket?.routes ?? []
        if let activeRoute,
           !routes.contains(where: { $0.id == activeRoute.id }) {
            routes.insert(activeRoute, at: 0)
        }
        guard !routes.isEmpty else { return nil }
        let now = runtime?.now() ?? Date()
        return MobilePairedMac(
            macDeviceID: macDeviceID,
            displayName: activeTicket?.macDisplayName ?? connectedHostName,
            routes: routes,
            createdAt: now,
            lastSeenAt: now,
            isActive: true,
            stackUserID: nil,
            instanceTag: activeMacInstanceTag
        )
    }

    /// Resolves the live foreground Mac that a failed destructive switch should restore.
    func previousForegroundMacForSwitchRestore(
        previousForegroundMacDeviceID: String?,
        previousForegroundInstanceTag: String? = nil,
        switchingTo macDeviceID: String,
        switchingToInstanceTag: String? = nil,
        storeMacs: [MobilePairedMac]
    ) -> MobilePairedMac? {
        guard let previousForegroundMacDeviceID,
              !previousForegroundMacDeviceID.isEmpty,
              previousForegroundDeviceMatchesTarget(
                  previousForegroundMacDeviceID,
                  previousForegroundInstanceTag,
                  switchingTo: macDeviceID,
                  switchingToInstanceTag: switchingToInstanceTag
              ) == false else { return nil }
        var seenIDs = Set<MacPairingKey>()
        let rawCandidates = storeMacs.isEmpty ? pairedMacs : storeMacs + pairedMacs
        let candidates = rawCandidates.filter { mac in
            seenIDs.insert(MacPairingKey(mac)).inserted
        }
        if let direct = candidates.first(where: {
            MacPairingKey($0) == MacPairingKey(
                macDeviceID: previousForegroundMacDeviceID,
                instanceTag: previousForegroundInstanceTag
            )
        }) {
            return direct
        }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        let aliasSetsByMacID = macDeviceIDAliasSetsByPairedMacID(
            in: candidates,
            supportedKinds: supportedKinds,
            preferNonLoopback: Self.prefersNonLoopbackRoutes
        )
        return candidates.first { candidate in
            guard MacPairingKey(candidate) != MacPairingKey(
                      macDeviceID: macDeviceID,
                      instanceTag: switchingToInstanceTag
                  ),
                  MacPairingKey(candidate).normalizedInstanceTag
                      == MacPairingKey(
                          macDeviceID: previousForegroundMacDeviceID,
                          instanceTag: previousForegroundInstanceTag
                      ).normalizedInstanceTag else { return false }
            return aliasSetsByMacID[candidate.id]?.contains(previousForegroundMacDeviceID) == true
        }
    }

    private func previousForegroundDeviceMatchesTarget(
        _ previousDeviceID: String,
        _ previousInstanceTag: String?,
        switchingTo targetDeviceID: String,
        switchingToInstanceTag: String?
    ) -> Bool {
        cmxCanonicalDeviceID(previousDeviceID) == cmxCanonicalDeviceID(targetDeviceID)
            && macInstanceTagAuthority.sameStoredAuthority(
                previousInstanceTag,
                switchingToInstanceTag
            )
    }

    /// Whether any foreground Mac switch attempt is currently in flight.
    ///
    /// `switchToMac` returns `false` both for a genuine connection failure and
    /// for an attempt superseded by a newer switch (which leaves the newer
    /// attempt's id in place; `finishMacSwitchAttempt` only clears a matching
    /// id). Reconnect UIs read this at result time to avoid showing a
    /// "couldn't connect" alert for an attempt that merely lost the race to a
    /// switch the user started elsewhere.
    ///
    /// Lives in an extension file (with `macSwitchAttemptID` made internal)
    /// instead of `MobileShellComposite.swift` to respect that file's length
    /// budget.
    public var isMacSwitchInFlight: Bool { macSwitchAttemptID != nil }

    func cancelMacSwitchAttempt(_ attemptID: UUID) -> Task<Bool, Never>? {
        macSwitchAttemptID == attemptID ? cancelPendingMacSwitch(restorePreviousOnCancel: true) : nil
    }

    func isCurrentMacSwitchAttempt(_ attemptID: UUID) -> Bool {
        macSwitchAttemptID == attemptID
            && macSwitchAttemptSignInGeneration == signInGeneration
            && isSignedIn
            && !Task.isCancelled
    }

    func finishMacSwitchAttempt(_ attemptID: UUID) {
        if macSwitchAttemptID == attemptID {
            macSwitchAttemptID = nil
            macSwitchAttemptSignInGeneration = nil
            macSwitchRestoreBaseline = nil
        }
        macSwitchRestorePreviousOnCancelAttemptIDs.remove(attemptID)
        if macSwitchAttemptID == nil {
            finishCompletedSecondaryMacDrainReservations()
        }
    }

    /// Assign any newly seen real Mac a stable in-memory color slot.
    ///
    /// Called from `recomputeDerivedWorkspaceState()` before deriving
    /// previews so a Mac switch's transient single-key `workspacesByMac`
    /// state (old foreground dropped synchronously, new foreground's
    /// siblings re-added asynchronously) never recomputes another Mac's
    /// existing slot. Lives here (with `stableMacColorSlots` and
    /// `workspaceAggregation` made internal) instead of
    /// `MobileShellComposite.swift` to respect that file's length budget.
    func updateStableMacColorSlots() {
        // Color is per exact app instance. Stable and Nightly are separate
        // computers, so their avatar slots must not be shared even when their
        // physical device id is the same.
        let updated = workspaceAggregation.machineColorIndex(
            existingAssignments: stableMacColorSlots,
            adding: workspacesByMac.keys
                .filter { $0 != .anonymousForeground }
                .map(\.pairingID)
        )
        if updated != stableMacColorSlots {
            stableMacColorSlots = updated
        }
    }

    /// Reset all stable color slots on sign-out. Slots are additive-only (see
    /// `updateStableMacColorSlots` above), so the anonymous-placeholder reset
    /// in `signOut()` never prunes the previous account's real Mac→color
    /// assignments on its own. Call this last, after every didSet-triggering
    /// assignment in `signOut()` has had its chance to recompute from the
    /// (still-stale) previous `workspacesByMac`, so the next account starts
    /// with a clean slate. Lives here instead of `MobileShellComposite.swift`
    /// to respect that file's length budget.
    func resetStableMacColorSlotsForSignOut() {
        stableMacColorSlots = [:]
    }

    /// Prune stable color slots to only the foreground app instance on a team
    /// switch.
    /// Slots are additive-only, so the old team's Macs would otherwise linger
    /// in the slot map forever across repeated team switches; the new team's
    /// Macs get reassigned lazily as they're re-aggregated. Lives here instead
    /// of `MobileShellComposite.swift` to respect that file's length budget.
    func pruneStableMacColorSlots(keepingForegroundKey foregroundKey: String) {
        stableMacColorSlots = stableMacColorSlots.filter { $0.key == foregroundKey }
    }
}
