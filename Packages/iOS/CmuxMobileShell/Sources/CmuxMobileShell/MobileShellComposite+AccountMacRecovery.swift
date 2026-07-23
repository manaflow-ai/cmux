import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

/// Presentation mode for explicit, user-triggered account computer recovery.
public enum MobileAccountComputerRecoveryMode: Equatable, Sendable {
    /// Account recovery is unavailable in the current shell composition.
    case unavailable
    /// Search the signed-in account without relying on local pairing history.
    case findAccountComputer
    /// A local deletion marker exists, so explain this as restoring a deletion.
    case recoverDeletedComputer
}

/// Result of an explicit, user-triggered account computer recovery attempt.
public enum MobileAccountComputerRecoveryResult: Equatable, Sendable {
    /// A Mac was found through same-account Iroh discovery and persisted.
    case recovered
    /// No eligible Mac was live for the current account/team scope.
    case notFound
    /// A previous recovery attempt is still running, so this tap did not start another scan.
    case alreadyInProgress
    /// The account or team changed while recovery was running.
    case staleScope
}

@MainActor
extension MobileShellComposite {
    /// How the UI should present explicit same-account computer recovery.
    public var accountComputerRecoveryMode: MobileAccountComputerRecoveryMode {
        guard isSignedIn,
              pairedMacStore != nil,
              personalIrohDiscovery != nil else { return .unavailable }
        return hasRecoverableDeletedComputers
            ? .recoverDeletedComputer
            : .findAccountComputer
    }

    /// Find and connect a Mac through live same-account Iroh discovery.
    ///
    /// Passive zero-touch discovery continues to exclude forgotten Macs. Explicit
    /// recovery is authorized by the current account's live broker snapshot instead
    /// of local pairing history. Forgotten candidates are tried first, and the
    /// normal Iroh connection path must still authenticate the Mac's device ID and
    /// app-instance tag before persistence clears any forgotten marker.
    @discardableResult
    public func recoverIrohMacFromAccount() async -> MobileAccountComputerRecoveryResult {
        guard !isRecoveringAccountComputer else { return .alreadyInProgress }
        isRecoveringAccountComputer = true
        defer { isRecoveringAccountComputer = false }

        guard isSignedIn,
              let scope = await currentScopeSnapshot(),
              let personalIrohDiscovery else { return .notFound }
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        let knownIDs = Set(pairedMacsForIdentityMatching.flatMap { mac in
            [mac.id, cmxCanonicalDeviceID(mac.macDeviceID)]
        })

        connectionRecoveryOwner.cancel()
        applyConnectionRecoveryOwnerState()
        invalidateStoredMacReconnectAttempt()

        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { return .staleScope }
        let candidates = accountIrohRecoveryCandidates(
            from: discovered,
            forgottenIDs: forgottenIDs,
            excludingKnownIDs: knownIDs
        )

        for mac in candidates {
            guard await isScopeCurrent(scope) else { return .staleScope }
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

    private func accountIrohRecoveryCandidates(
        from discovered: [MobileDiscoveredIrohMac],
        forgottenIDs: Set<String>,
        excludingKnownIDs knownIDs: Set<String>
    ) -> [MobileDiscoveredIrohMac] {
        var seen: Set<String> = []
        var forgottenCandidates: [MobileDiscoveredIrohMac] = []
        var unpairedCandidates: [MobileDiscoveredIrohMac] = []
        for mac in discovered {
            let canonicalDeviceID = cmxCanonicalDeviceID(mac.deviceID)
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: canonicalDeviceID,
                instanceTag: mac.instanceTag
            )
            let isForgotten = forgottenIDs.contains(canonicalDeviceID)
                || forgottenIDs.contains(pairingID)
            let isKnown = knownIDs.contains(canonicalDeviceID)
                || knownIDs.contains(pairingID)
            guard isForgotten || !isKnown,
                  !mac.routes.isEmpty,
                  mac.routes.contains(where: { $0.kind == .iroh }),
                  seen.insert(pairingID).inserted else { continue }
            if isForgotten {
                forgottenCandidates.append(mac)
            } else {
                unpairedCandidates.append(mac)
            }
        }
        return Array(
            (forgottenCandidates + unpairedCandidates)
                .prefix(Self.maximumAutomaticIrohCandidateCount)
        )
    }
}
