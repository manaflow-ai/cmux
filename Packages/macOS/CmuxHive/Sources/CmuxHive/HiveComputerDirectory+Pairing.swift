internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import CmuxMobileShell
internal import CmuxMobileShellModel
public import Foundation

/// Pairing mutations share the directory’s account generation and refresh path.
extension HiveComputerDirectory {
    /// Pair a computer from its registry row: persist its best instance's
    /// routes into the local paired store.
    public func pair(deviceID: String) async -> HivePairOutcome {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        let scope = await scopeProvider()
        guard scope.stackUserID != nil else { return .storeFailed }
        if loadedScope != scope {
            await refresh()
            guard loadedScope == scope else { return .noRoutes }
        }
        // Pairing with the computer you are sitting at is always a mistake
        // (dev builds advertise loopback routes, so it would even "work").
        guard deviceID != ownDeviceID else {
            return .loopbackRejected
        }
        guard let computer = computers.first(where: { $0.deviceID == deviceID }),
              computer.isPairableHost,
              computer.isOwnedByCurrentUser,
              computer.hasViewerSupportedRoute else {
            return .noRoutes
        }
        guard let best = computer.bestPairingRoutes else { return .noRoutes }
        return await persistPairing(
            macDeviceID: deviceID,
            displayName: computer.displayName,
            routes: best.routes,
            instanceTag: best.instanceTag,
            scope: scope
        )
    }

    /// Pair from the 6-digit code another Mac's "Pair This Mac" row is
    /// showing.
    ///
    /// The code is a registry rendezvous: the host advertises it (with an
    /// expiry) in its instance labels, so the claim re-fetches the registry
    /// and pairs with the unique instance whose unexpired code matches.
    /// Non-digits in the input are ignored, so `"042 117"` claims `042117`.
    ///
    /// - Parameter rawCode: The user-typed code.
    /// - Returns: The pair outcome; ambiguous or expired codes report
    ///   ``HivePairOutcome/codeNotFound``.
    public func pair(code rawCode: String) async -> HivePairOutcome {
        guard let code = CmxPairingCode.normalizedClaimInput(rawCode) else {
            return .codeNotFound
        }
        await refresh()
        let scope = await scopeProvider()
        guard scope.stackUserID != nil, loadedScope == scope else { return .codeNotFound }
        let claimTime = now()
        let matches = registryDevices.flatMap { device in
            device.instances
                // Pairing-code claims use the registry snapshot directly. Keep
                // the label-bearing `RegistryAppInstance` at this boundary;
                // the settings row model intentionally omits labels because
                // they are rendezvous metadata, not UI state.
                .filter {
                    !$0.routes.isEmpty
                        && CmxPairingCode.active(in: $0.labels, now: claimTime)?.code == code
                }
                .map { (device: device, instance: $0) }
        }
        // Exactly one live match may claim; a 6-digit collision inside one
        // team is ambiguous and reports not-found rather than guessing.
        guard matches.count == 1, let match = matches.first else { return .codeNotFound }
        guard match.device.isOwnedByCurrentUser,
              match.instance.routes.contains(where: { viewerRoutePolicy.supports($0) }) else {
            return .noRoutes
        }
        guard match.device.isControllableHost else { return .noRoutes }
        guard cmxCanonicalDeviceID(match.device.deviceId) != ownDeviceID else {
            return .loopbackRejected
        }
        return await persistPairing(
            macDeviceID: match.device.deviceId,
            displayName: match.device.displayName,
            routes: match.instance.routes,
            instanceTag: match.instance.tag,
            scope: scope
        )
    }

    /// Pair from a pasted pairing link (the QR payload another Mac shows).
    public func pair(link rawLink: String) async -> HivePairOutcome {
        let scope = await scopeProvider()
        guard scope.stackUserID != nil else { return .accountMismatch }
        if loadedScope == nil {
            _ = activateScope(scope)
        } else if loadedScope != scope {
            await refresh()
            guard loadedScope == scope else { return .accountMismatch }
        }
        switch linkDecoder.decode(rawLink, currentStackUserID: scope.stackUserID) {
        case .invalidLink:
            return .invalidLink
        case .loopbackRejected:
            return .loopbackRejected
        case .accountMismatch:
            return .accountMismatch
        case .ticket(let ticket):
            // The v2 pairing grammar deliberately carries no device id or
            // display name (identity arrives post-handshake from
            // `mobile.host.status`), so mirror the iOS manual-host flow: pair
            // under a synthetic id derived from the dialable endpoint and let
            // the first connection adopt the host-reported identity.
            let macDeviceID: String
            if ticket.macDeviceID.isEmpty {
                guard !ticket.routes.contains(where: { $0.kind == .tailscale }) else {
                    // A tokenless V2 link intentionally omits the host
                    // identity. Do not persist a synthetic Tailscale row: it
                    // could never pass the viewer's authenticated admission
                    // and would report a misleading successful pairing.
                    return .unsupportedManualRoute
                }
                guard let synthesized = Self.syntheticDeviceID(for: ticket.routes) else {
                    return .invalidLink
                }
                macDeviceID = synthesized
            } else {
                macDeviceID = ticket.macDeviceID
            }
            guard cmxCanonicalDeviceID(macDeviceID) != ownDeviceID else {
                return .loopbackRejected
            }
            return await persistPairing(
                macDeviceID: macDeviceID,
                displayName: ticket.macDisplayName ?? Self.endpointLabel(for: ticket.routes),
                routes: ticket.routes,
                instanceTag: nil,
                scope: scope
            )
        }
    }

    /// The iOS-compatible synthetic identity for a link that names no device:
    /// `manual-<host>:<port>` from the first dialable route.
    static func syntheticDeviceID(for routes: [CmxAttachRoute]) -> String? {
        endpointLabel(for: routes).map { "manual-\($0)" }
    }

    private static func endpointLabel(for routes: [CmxAttachRoute]) -> String? {
        for route in routes {
            if case let .hostPort(host, port) = route.endpoint {
                return "\(host):\(port)"
            }
        }
        return nil
    }

    /// Remove the local pairing record for a computer. Registry rows remain
    /// visible; only the pairing (persisted routes) is forgotten.
    /// - Returns: `true` when the store accepted the removal.
    @discardableResult
    public func unpair(deviceID: String) async -> Bool {
        let deviceID = cmxCanonicalDeviceID(deviceID)
        let scope = await scopeProvider()
        let generation = scopeGeneration
        guard scope.stackUserID != nil,
              loadedScope == scope,
              await isCurrentScope(scope, generation: generation) else {
            return false
        }
        do {
            try await pairedStore.remove(
                macDeviceID: deviceID,
                stackUserID: scope.stackUserID,
                teamID: scope.teamID
            )
        } catch {
            return false
        }
        guard await isCurrentScope(scope, generation: generation) else { return false }
        await reloadPairedRecords(scope: scope)
        guard await isCurrentScope(scope, generation: generation) else { return false }
        rebuild()
        return true
    }

    private func persistPairing(
        macDeviceID: String,
        displayName: String?,
        routes: [CmxAttachRoute],
        instanceTag: String?,
        scope: HiveAccountScope
    ) async -> HivePairOutcome {
        let macDeviceID = cmxCanonicalDeviceID(macDeviceID)
        let routes = viewerRoutePolicy.supportedRoutes(routes)
        guard !routes.isEmpty else { return .noRoutes }
        let generation = scopeGeneration
        guard await isCurrentScope(scope, generation: generation) else {
            return .accountMismatch
        }
        do {
            try await pairedStore.upsert(
                macDeviceID: macDeviceID,
                displayName: displayName,
                routes: routes,
                instanceTag: instanceTag,
                markActive: false,
                stackUserID: scope.stackUserID,
                teamID: scope.teamID,
                now: now()
            )
        } catch {
            return .storeFailed
        }
        guard await isCurrentScope(scope, generation: generation) else {
            return .accountMismatch
        }
        await reloadPairedRecords(scope: scope)
        guard await isCurrentScope(scope, generation: generation) else {
            return .accountMismatch
        }
        rebuild()
        return .paired(deviceID: macDeviceID)
    }
}
