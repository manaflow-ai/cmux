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
                  await !isForgottenMacDeviceID(
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
}
