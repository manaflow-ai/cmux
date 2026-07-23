import CMUXMobileCore
import CmuxMobilePairedMac
import Foundation
internal import OSLog

private let hiddenRecoveryLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

/// Result of a user-triggered legacy hidden-computer recovery attempt.
public enum MobileHiddenComputerRecoveryResult: Equatable, Sendable {
    /// A hidden Mac was found through same-account Iroh discovery and persisted again.
    case recovered
    /// No eligible hidden Mac was live for the current account/team scope.
    ///
    /// A `nil` reason retains the generic fallback for failures that cannot be
    /// attributed to discovery identity or route availability.
    case notFound(reason: MobileHiddenComputerRecoveryFailureReason? = nil)
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
              let scope = await currentScopeSnapshot() else { return .notFound() }
        guard let personalIrohDiscovery else {
            // Signed in but this phone has no Iroh discovery client (e.g. a
            // legacy Tailscale-only pairing where phone-side Iroh was never
            // provisioned). Recovery cannot search anything in that state.
            hiddenRecoveryLog.info("hidden recovery aborted: iroh discovery unavailable on this device")
            return .notFound(reason: .irohUnavailable)
        }
        let hiddenIDs = await hiddenMacDeviceIDs(scope: scope)
        guard !hiddenIDs.isEmpty else { return .notFound() }

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

        var attemptedConnects = 0
        for mac in candidates {
            guard await isScopeCurrent(scope) else { return .staleScope }
            guard await isHiddenMacDeviceID(
                mac.deviceID,
                instanceTag: mac.instanceTag,
                scope: scope
            ) else { continue }
            attemptedConnects += 1
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
            guard recovered else {
                hiddenRecoveryLog.info(
                    "hidden recovery connect failed mac=\(mac.deviceID, privacy: .public) tag=\(mac.instanceTag, privacy: .public)"
                )
                continue
            }
            await loadPairedMacs()
            await loadRegistryDevices()
            return .recovered
        }
        // A candidate matched the marker exactly and advertised an Iroh route,
        // so the residual failure is the authenticated connect, not discovery.
        let reason: MobileHiddenComputerRecoveryFailureReason? = attemptedConnects > 0
            ? .connectFailed
            : hiddenIrohRecoveryFailureReason(
                from: discovered,
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            )
        hiddenRecoveryLog.info(
            "hidden recovery notFound hidden=\(hiddenIDs.count) discovered=\(discovered.count) candidates=\(candidates.count) attempted=\(attemptedConnects) target=\(macDeviceID.map(cmxCanonicalDeviceID) ?? "-", privacy: .public) tag=\(instanceTag ?? "-", privacy: .public) reason=\(String(describing: reason), privacy: .public)"
        )
        return .notFound(reason: reason)
    }

    private func hiddenIrohRecoveryFailureReason(
        from discovered: [MobileDiscoveredIrohMac],
        macDeviceID: String?,
        instanceTag: String?
    ) -> MobileHiddenComputerRecoveryFailureReason? {
        guard let macDeviceID else { return nil }
        let canonicalDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let deviceMatches = discovered.filter {
            cmxCanonicalDeviceID($0.deviceID) == canonicalDeviceID
        }
        guard !deviceMatches.isEmpty else { return .deviceNotFound }

        let instanceMatches = deviceMatches.filter { $0.instanceTag == instanceTag }
        guard !instanceMatches.isEmpty else {
            return .instanceNotLive(instanceTag: instanceTag)
        }
        guard instanceMatches.contains(where: {
            $0.routes.contains(where: { $0.kind == .iroh })
        }) else {
            return .noIrohRoute
        }
        return nil
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
