import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

/// Result of a user-triggered legacy hidden-computer recovery attempt.
public enum MobileHiddenComputerRecoveryResult: Equatable, Sendable {
    /// A hidden Mac was found through same-account Iroh discovery and persisted again.
    case recovered
    /// No eligible hidden Mac was live for the current account/team scope.
    case notFound
    /// A previous recovery attempt is still running, so this tap did not start another scan.
    case alreadyInProgress
    /// The account or team changed while recovery was running.
    case staleScope
}

@MainActor
extension MobileShellComposite {
    /// Recovers a legacy hidden entry through live same-account Iroh discovery.
    ///
    /// Local hidden rows use ``unhideMacDeviceID(_:instanceTag:)`` and never come
    /// through this path. Passive zero-touch discovery still excludes hidden
    /// Macs; this explicit path authenticates a matching live candidate before
    /// persistence clears the hidden marker and revives any legacy tombstone.
    /// - Parameters:
    ///   - macDeviceID: Optional physical Mac id used to scope a per-entry attempt.
    ///   - instanceTag: Optional app-instance tag used to scope a per-entry attempt.
    /// - Returns: The terminal result of the live recovery attempt.
    @discardableResult
    public func recoverHiddenIrohMacFromAccount(
        macDeviceID: String? = nil,
        instanceTag: String? = nil
    ) async -> MobileHiddenComputerRecoveryResult {
        guard !isRecoveringHiddenComputer else { return .alreadyInProgress }
        isRecoveringHiddenComputer = true
        defer { isRecoveringHiddenComputer = false }

        guard isSignedIn,
              let scope = await currentScopeSnapshot(),
              let personalIrohDiscovery else { return .notFound }
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        guard !hiddenIDs.isEmpty else { return .notFound }

        connectionRecoveryOwner.cancel()
        applyConnectionRecoveryOwnerState()
        invalidateStoredMacReconnectAttempt()

        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { return .staleScope }
        let candidates = hiddenIrohRecoveryCandidates(
            from: discovered,
            hiddenIDs: hiddenIDs,
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )

        for mac in candidates {
            guard await isScopeCurrent(scope) else { return .staleScope }
            guard await isHiddenMacDeviceID(
                mac.deviceID,
                instanceTag: mac.instanceTag,
                scope: scope
            ) else { continue }
            let recovered = await connectAccountDiscoveredIrohMac(
                mac,
                accountID: scope.userID,
                ifStillCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.isSignedIn
                        && self.secondaryAggregationScopeGeneration == scope.generation
                        && self.identityProvider?.currentUserID == scope.userID
                }
            )
            guard await isScopeCurrent(scope) else { return .staleScope }
            guard recovered else { continue }
            await loadPairedMacs()
            await loadRegistryDevices()
            return .recovered
        }
        return .notFound
    }

    private func hiddenIrohRecoveryCandidates(
        from discovered: [MobileDiscoveredIrohMac],
        hiddenIDs: Set<String>,
        macDeviceID: String?,
        instanceTag: String?
    ) -> [MobileDiscoveredIrohMac] {
        var seen: Set<String> = []
        var candidates: [MobileDiscoveredIrohMac] = []
        for mac in discovered {
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: mac.deviceID,
                instanceTag: mac.instanceTag
            )
            if let macDeviceID,
               cmxCanonicalDeviceID(mac.deviceID) != cmxCanonicalDeviceID(macDeviceID) {
                continue
            }
            if let instanceTag, mac.instanceTag != instanceTag {
                continue
            }
            guard hiddenIDs.contains(cmxCanonicalDeviceID(mac.deviceID))
                    || hiddenIDs.contains(pairingID),
                  !mac.routes.isEmpty,
                  mac.routes.contains(where: { $0.kind == .iroh }),
                  seen.insert(pairingID).inserted else { continue }
            candidates.append(mac)
            if candidates.count == Self.maximumAutomaticIrohCandidateCount {
                break
            }
        }
        return candidates
    }
}
