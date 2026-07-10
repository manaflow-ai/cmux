internal import CMUXMobileCore
internal import CmuxMobilePairedMac
internal import Foundation
internal import OSLog

private let mobileIrohPinLog = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "dev.cmux.ios",
    category: "mobile-shell"
)

@MainActor
extension MobileShellComposite {
    func tokenBearingDialableRoutes(for mac: MobilePairedMac) -> [CmxAttachRoute] {
        MobileIrohPinPolicy().tokenBearingDialableRoutes(
            mac.routes,
            pinnedEndpointID: mac.pinnedIrohEndpointID
        )
    }

    func tokenBearingDialableRoutes(
        for ticket: CmxAttachTicket,
        candidateRoutes: [CmxAttachRoute]
    ) async -> [CmxAttachRoute] {
        guard candidateRoutes.contains(where: { $0.kind == .iroh }) else {
            return candidateRoutes
        }
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              !ticket.macDeviceID.hasPrefix("manual-"),
              let scope = await currentScopeSnapshot(userID: identityProvider?.currentUserID) else {
            return MobileIrohPinPolicy().tokenBearingDialableRoutes(candidateRoutes, pinnedEndpointID: nil)
        }
        do {
            let pin = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                .first { $0.macDeviceID == ticket.macDeviceID }?
                .pinnedIrohEndpointID
            guard await isScopeCurrent(scope) else { return [] }
            return MobileIrohPinPolicy().tokenBearingDialableRoutes(candidateRoutes, pinnedEndpointID: pin)
        } catch {
            mobileIrohPinLog.error("iroh pin lookup for ticket failed mac=\(ticket.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return candidateRoutes.filter { $0.kind != .iroh }
        }
    }

    func ticketHasPinnedIrohIdentityMismatch(
        _ ticket: CmxAttachTicket,
        candidateRoutes: [CmxAttachRoute]
    ) async -> Bool {
        guard candidateRoutes.contains(where: { $0.kind == .iroh }),
              let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              !ticket.macDeviceID.hasPrefix("manual-"),
              let scope = await currentScopeSnapshot(userID: identityProvider?.currentUserID) else {
            return false
        }
        do {
            let pin = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                .first { $0.macDeviceID == ticket.macDeviceID }?
                .pinnedIrohEndpointID
            guard await isScopeCurrent(scope) else { return false }
            return MobileIrohPinPolicy().hasMismatch(
                routes: candidateRoutes,
                pinnedEndpointID: pin
            )
        } catch {
            mobileIrohPinLog.error("iroh pin mismatch lookup for ticket failed mac=\(ticket.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return false
        }
    }

    func routeAllowsTokenBearingDial(_ route: CmxAttachRoute, pinnedIrohEndpointID: String?) -> Bool {
        MobileIrohPinPolicy()
            .classification(for: route, pinnedEndpointID: pinnedIrohEndpointID)
            .allowsTokenBearingDial
    }

    public func hasIrohIdentityMismatch(for macDeviceID: String) -> Bool {
        let aliases = Set(pairedMacAliasIDs(for: macDeviceID))
        return pairedMacsForIdentityMatching.contains { mac in
            aliases.contains(mac.macDeviceID)
                && MobileIrohPinPolicy().hasMismatch(
                    routes: mac.routes,
                    pinnedEndpointID: mac.pinnedIrohEndpointID
                )
        }
    }

    public func trustCurrentIrohIdentity(macDeviceID: String) async {
        guard let pairedMacStore,
              let scope = await currentScopeSnapshot() else { return }
        let aliases = Set(pairedMacAliasIDs(for: macDeviceID))
        let macs: [MobilePairedMac]
        do {
            macs = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
        } catch {
            mobileIrohPinLog.error("iroh re-trust load failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        guard await isScopeCurrent(scope) else { return }
        let policy = MobileIrohPinPolicy()
        let target = macs.first {
            aliases.contains($0.macDeviceID)
                && policy.hasMismatch(routes: $0.routes, pinnedEndpointID: $0.pinnedIrohEndpointID)
        } ?? macs.first { aliases.contains($0.macDeviceID) }
        guard let target,
              let endpointID = policy.firstIrohEndpointID(in: target.routes) else { return }
        do {
            try await pairedMacStore.setPinnedIrohEndpointID(
                macDeviceID: target.macDeviceID,
                endpointID: endpointID,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: Date()
            )
        } catch {
            mobileIrohPinLog.error("iroh re-trust pin write failed mac=\(target.macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return
        }
        await loadPairedMacs()
        _ = await switchToMac(macDeviceID: target.macDeviceID)
    }

    func persistIrohPinFromAcceptedPairingTicket(_ ticket: CmxAttachTicket) async {
        guard let pairedMacStore,
              !ticket.macDeviceID.isEmpty,
              !ticket.macDeviceID.hasPrefix("manual-"),
              let endpointID = MobileIrohPinPolicy().firstIrohEndpointID(in: ticket.routes),
              let scope = await currentScopeSnapshot(userID: identityProvider?.currentUserID) else { return }
        do {
            let currentPin = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                .first { $0.macDeviceID == ticket.macDeviceID }?
                .pinnedIrohEndpointID
            guard await isScopeCurrent(scope) else { return }
            if let currentPin, currentPin != endpointID {
                mobileIrohPinLog.info("accepted QR iroh pin mismatch left unchanged mac=\(ticket.macDeviceID, privacy: .public)")
                return
            }
            try await pairedMacStore.setPinnedIrohEndpointID(
                macDeviceID: ticket.macDeviceID,
                endpointID: endpointID,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: Date()
            )
        } catch {
            mobileIrohPinLog.debug("accepted QR iroh pin write skipped: \(String(describing: error), privacy: .public)")
        }
    }

    func persistIrohPinAfterSuccessfulAttach(
        macDeviceID: String,
        route: CmxAttachRoute
    ) async {
        guard let pairedMacStore,
              !macDeviceID.isEmpty,
              !macDeviceID.hasPrefix("manual-"),
              let scope = await currentScopeSnapshot(userID: identityProvider?.currentUserID) else { return }
        let current: MobilePairedMac?
        do {
            current = try await pairedMacStore.loadAll(stackUserID: scope.userID, teamID: scope.teamID)
                .first { $0.macDeviceID == macDeviceID }
        } catch {
            mobileIrohPinLog.debug("iroh pin lookup failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard await isScopeCurrent(scope),
              let endpointID = MobileIrohPinPolicy().endpointIDToPinAfterSuccessfulDial(
                route: route,
                pinnedEndpointID: current?.pinnedIrohEndpointID
              ) else { return }
        do {
            try await pairedMacStore.setPinnedIrohEndpointID(
                macDeviceID: macDeviceID,
                endpointID: endpointID,
                stackUserID: scope.userID,
                teamID: scope.teamID,
                now: Date()
            )
        } catch {
            mobileIrohPinLog.error("iroh first-trust pin write failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
    }
}
