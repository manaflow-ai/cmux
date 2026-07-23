import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation

@MainActor
extension MobileShellComposite {
    /// Recover a deleted Mac through live same-account Iroh discovery.
    ///
    /// Passive zero-touch discovery continues to exclude forgotten Macs. This
    /// method is the explicit user recovery path: it only considers live broker
    /// candidates that match a remembered forgotten ID, then the normal Iroh
    /// connection path must authenticate the Mac's device ID and app-instance tag
    /// before persistence clears the forgotten marker.
    @discardableResult
    public func recoverForgottenIrohMacFromAccount() async -> Bool {
        guard !isRecoveringDeletedComputer else { return false }
        isRecoveringDeletedComputer = true
        defer { isRecoveringDeletedComputer = false }

        guard isSignedIn,
              let scope = await currentScopeSnapshot(),
              let personalIrohDiscovery else { return false }
        let forgottenIDs = await forgottenMacDeviceIDs(scope: scope)
        guard !forgottenIDs.isEmpty else { return false }

        connectionRecoveryOwner.cancel()
        applyConnectionRecoveryOwnerState()
        invalidateStoredMacReconnectAttempt()

        let discovered = await personalIrohDiscovery.discoverLiveMacs()
        guard await isScopeCurrent(scope) else { return false }
        let candidates = forgottenIrohRecoveryCandidates(
            from: discovered,
            forgottenIDs: forgottenIDs
        )

        for mac in candidates {
            guard await isScopeCurrent(scope) else { return false }
            guard await isForgottenMacDeviceID(
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
                        && self.identityProvider?.currentUserID == scope.userID
                }
            )
            guard recovered else { continue }
            await loadPairedMacs()
            await loadRegistryDevices()
            return true
        }
        return false
    }

    private func forgottenIrohRecoveryCandidates(
        from discovered: [MobileDiscoveredIrohMac],
        forgottenIDs: Set<String>
    ) -> [MobileDiscoveredIrohMac] {
        var seen: Set<String> = []
        var candidates: [MobileDiscoveredIrohMac] = []
        for mac in discovered {
            let pairingID = MobilePairedMac.pairingID(
                macDeviceID: mac.deviceID,
                instanceTag: mac.instanceTag
            )
            guard forgottenIDs.contains(cmxCanonicalDeviceID(mac.deviceID))
                    || forgottenIDs.contains(pairingID),
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
