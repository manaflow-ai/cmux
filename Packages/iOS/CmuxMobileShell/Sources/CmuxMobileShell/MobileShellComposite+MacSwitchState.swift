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
        switchingTo macDeviceID: String,
        storeMacs: [MobilePairedMac]
    ) -> MobilePairedMac? {
        guard let previousForegroundMacDeviceID,
              !previousForegroundMacDeviceID.isEmpty,
              previousForegroundMacDeviceID != macDeviceID else { return nil }
        var seenIDs = Set<String>()
        let rawCandidates = storeMacs.isEmpty ? pairedMacs : storeMacs + pairedMacs
        let candidates = rawCandidates.filter { mac in
            seenIDs.insert(mac.macDeviceID).inserted
        }
        if let direct = candidates.first(where: {
            $0.macDeviceID == previousForegroundMacDeviceID && $0.macDeviceID != macDeviceID
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
            guard candidate.macDeviceID != macDeviceID else { return false }
            return aliasSetsByMacID[candidate.macDeviceID]?.contains(previousForegroundMacDeviceID) == true
        }
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
        let updated = workspaceAggregation.machineColorIndex(
            existingAssignments: stableMacColorSlots,
            adding: Array(workspacesByMac.keys.filter { !$0.isEmpty && $0 != Self.foregroundAnonymousKey })
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

    /// Prune stable color slots to only the foreground Mac on a team switch.
    /// Slots are additive-only, so the old team's Macs would otherwise linger
    /// in the slot map forever across repeated team switches; the new team's
    /// Macs get reassigned lazily as they're re-aggregated. Lives here instead
    /// of `MobileShellComposite.swift` to respect that file's length budget.
    func pruneStableMacColorSlots(keepingForegroundKey foregroundKey: String) {
        stableMacColorSlots = stableMacColorSlots.filter { $0.key == foregroundKey }
    }
}
