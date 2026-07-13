import CMUXMobileCore
import CmuxMobilePairedMac

@MainActor
extension MobileShellComposite {
    func connectStoredMacHost(
        name: String,
        host: String,
        port: Int,
        pairedMacDeviceID: String,
        instanceTag: String? = nil,
        persistsPairedMac: Bool = true,
        ifStillCurrent: (() -> Bool)? = nil
    ) async {
        await connectManualHost(
            name: name,
            host: host,
            port: port,
            pairedMacDeviceID: pairedMacDeviceID,
            instanceTagExpectation: MobileMacInstanceTagAuthority.expectation(
                storedInstanceTag: instanceTag
            ),
            recordsPairingAttempt: false,
            clearsForgottenMac: false,
            persistsPairedMac: persistsPairedMac,
            ifStillCurrent: ifStillCurrent
        )
    }

    /// Retry lane used while one cancellation-insensitive store read is retired.
    /// It dials only the current in-memory paired-Mac snapshot and performs no
    /// paired-Mac reads or writes, so a wedged store cannot make Retry inert or
    /// accumulate another suspended store operation.
    func performCachedStoredMacReconnect() async -> StoredMacReconnectOutcome {
        startObservingNetworkPathChanges()
        storedMacReconnectGeneration &+= 1
        let generation = storedMacReconnectGeneration
        storedMacReconnectTargetDeviceID = nil
        defer {
            if generation == storedMacReconnectGeneration {
                storedMacReconnectTargetDeviceID = nil
            }
        }
        guard isSignedIn else { return .failed }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        func reachableRoutes(_ mac: MobilePairedMac) -> [(host: String, port: Int, routeID: String)] {
            Self.reconnectHostPortRoutes(
                mac.routes,
                supportedKinds: supportedKinds,
                preferNonLoopback: Self.prefersNonLoopbackRoutes
            )
        }
        let cachedMacs = pairedMacsForIdentityMatching
        let activeMac = cachedMacs.first { $0.isActive && !reachableRoutes($0).isEmpty }
        var candidates = activeMac.map { [$0] } ?? []
        candidates.append(contentsOf: cachedMacs.filter {
            $0.macDeviceID != activeMac?.macDeviceID && !reachableRoutes($0).isEmpty
        })
        guard !candidates.isEmpty else { return .unavailable }
        setHasKnownPairedMac(true, generation: generation)
        for mac in candidates {
            guard generation == storedMacReconnectGeneration else { return .failed }
            storedMacReconnectTargetDeviceID = mac.macDeviceID
            for route in reachableRoutes(mac) {
                guard generation == storedMacReconnectGeneration else { return .failed }
                await connectStoredMacHost(
                    name: mac.displayName ?? route.host,
                    host: route.host,
                    port: route.port,
                    pairedMacDeviceID: mac.macDeviceID,
                    instanceTag: mac.instanceTag,
                    persistsPairedMac: false,
                    ifStillCurrent: { [weak self] in
                        self?.storedMacReconnectGeneration == generation
                            && self?.storedMacReconnectTargetDeviceID == mac.macDeviceID
                    }
                )
                if connectionState == .connected { return .connected }
            }
        }
        return .failed
    }
}
