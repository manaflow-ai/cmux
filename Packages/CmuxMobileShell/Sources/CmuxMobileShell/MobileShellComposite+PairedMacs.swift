public import CMUXMobileCore
internal import CmuxMobileDiagnostics
public import CmuxMobilePairedMac
public import CmuxMobileRPC
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import CmuxMobileTransport
public import Foundation
import Observation
internal import OSLog


// MARK: - Paired Mac switching
extension MobileShellComposite {
    /// Reload ``pairedMacs`` from the store, scoped to the signed-in Stack user.
    ///
    /// A missing current Stack user id yields no pairings rather than falling
    /// back to the unscoped all-users query, so a shared device never exposes
    /// another user's Macs in the switcher.
    public func loadPairedMacs() async {
        guard let pairedMacStore, isSignedIn,
              let stackUserID = identityProvider?.currentUserID else {
            pairedMacs = []
            return
        }
        let loaded: [MobilePairedMac]
        do {
            loaded = try await pairedMacStore.loadAll(stackUserID: stackUserID)
        } catch {
            mobileShellLog.error("paired mac store loadAll failed: \(String(describing: error), privacy: .public)")
            return
        }
        // The await above suspended the main actor; a sign-out or user switch may
        // have run meanwhile. Discard the result unless we are still the same
        // signed-in user, so a slow load can never repopulate another user's hosts.
        guard isSignedIn, identityProvider?.currentUserID == stackUserID else {
            pairedMacs = []
            return
        }
        pairedMacs = loaded
    }

    /// Switch the live connection to `macDeviceID`, persisting it as the active
    /// pairing only on a successful connect.
    ///
    /// The underlying connect path is destructive (it replaces the live client),
    /// so a failed switch to an offline/stale Mac would drop the working session.
    /// To avoid stranding the user, the store's active row is only updated on a
    /// successful connect, and on failure the previously-active Mac (still the
    /// active row) is reconnected. A no-op when already connected to that Mac.
    /// - Parameter macDeviceID: The stored Mac to switch to.
    public func switchToMac(macDeviceID: String) async {
        guard let pairedMacStore,
              let target = pairedMacs.first(where: { $0.macDeviceID == macDeviceID }) else { return }
        if target.isActive, connectionState == .connected { return }
        // The currently-active Mac to fall back to if the switch fails.
        let previousActive = pairedMacs.first { $0.isActive && $0.macDeviceID != macDeviceID }
        let supportedKinds = runtime?.supportedRouteKinds ?? []
        guard let (host, port) = Self.firstReconnectHostPortRoute(
            target.routes,
            supportedKinds: supportedKinds
        ), let normalizedHost = MobileShellRouteAuthPolicy.normalizedManualHost(host) else {
            mobileShellLog.error("switchToMac: no reconnectable route mac=\(macDeviceID, privacy: .public)")
            return
        }
        await connectManualHost(name: target.displayName ?? host, host: host, port: port)
        // Persist the active row only if the live connection is to THIS Mac's
        // route. A different switch tapped while this connect was in flight
        // supersedes it via `beginPairingAttempt`, leaving `connectionState`
        // `.connected` for the other Mac; matching the live route prevents this
        // superseded task from persisting a stale active target.
        if connectionState == .connected,
           case let .hostPort(liveHost, livePort)? = activeRoute?.endpoint,
           liveHost == normalizedHost, livePort == port {
            do {
                try await pairedMacStore.setActive(macDeviceID: macDeviceID)
            } catch {
                mobileShellLog.error("paired mac store setActive failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        } else if previousActive != nil, connectionState != .connected {
            // The switch did not connect and the destructive connect path dropped
            // the previous session; reconnect to the still-active previous Mac so
            // the user is not left stranded on a failed switch.
            _ = await reconnectActiveMacIfAvailable(stackUserID: identityProvider?.currentUserID)
        }
        await loadPairedMacs()
    }

    /// Forget `macDeviceID`. Always removes the selected stored row by its real
    /// id, and additionally tears down the live connection when that row is the
    /// active one (the live attach ticket can carry a transient manual id, so we
    /// must not rely on it to identify the row being forgotten).
    /// - Parameter macDeviceID: The stored Mac to forget.
    public func forgetMac(macDeviceID: String) async {
        let isActiveMac = pairedMacs.first(where: { $0.macDeviceID == macDeviceID })?.isActive ?? false
        if isActiveMac, connectionState == .connected {
            disconnectLiveConnection()
        }
        do {
            try await pairedMacStore?.remove(macDeviceID: macDeviceID)
        } catch {
            mobileShellLog.error("paired mac store remove failed mac=\(macDeviceID, privacy: .public) error=\(String(describing: error), privacy: .public)")
        }
        await loadPairedMacs()
    }

    static func firstReconnectHostPortRoute(
        _ routes: [CmxAttachRoute],
        supportedKinds: [CmxAttachTransportKind]
    ) -> (String, Int)? {
        let supportedKinds = Set(supportedKinds)
        for route in routes.sorted(by: routeSortsBefore) {
            if !supportedKinds.isEmpty, !supportedKinds.contains(route.kind) {
                continue
            }
            if case let .hostPort(host, port) = route.endpoint {
                return (host, port)
            }
        }
        return nil
    }

    func persistPairedMacFromTicket(_ ticket: CmxAttachTicket) async {
        guard let pairedMacStore else { return }
        guard !ticket.macDeviceID.isEmpty else { return }
        // Strip routes that we can't reconnect to without server-side state
        // (manual-workspace routes have no real macDeviceID and aren't useful).
        guard ticket.macDeviceID != "manual-ticket-request",
              !ticket.macDeviceID.hasPrefix("manual-") else { return }
        let stackUserID = identityProvider?.currentUserID
        do {
            try await pairedMacStore.upsert(
                macDeviceID: ticket.macDeviceID,
                displayName: ticket.macDisplayName,
                routes: ticket.routes,
                markActive: true,
                stackUserID: stackUserID
            )
            // A real, reconnectable Mac is now the active paired Mac: record the
            // persisted hint so the next launch shows RestoringSessionView during
            // the reconnect window instead of the empty add-device sheet.
            hasKnownPairedMac = true
        } catch {
            mobileShellLog.error("paired mac store upsert failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func manualHostRoute(host: String, port: Int) throws -> CmxAttachRoute {
        let routeKind = MobileShellRouteAuthPolicy.manualRouteKind(for: host)
        return try CmxAttachRoute(
            id: routeKind.rawValue,
            kind: routeKind,
            endpoint: .hostPort(host: host, port: port)
        )
    }

    static func routeSortsBefore(_ left: CmxAttachRoute, _ right: CmxAttachRoute) -> Bool {
        if left.priority == right.priority {
            return left.id < right.id
        }
        return left.priority < right.priority
    }

}
