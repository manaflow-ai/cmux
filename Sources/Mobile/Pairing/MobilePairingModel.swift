import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in (authorization is a Stack same-account check), then turns on the pairing
/// host and mints a transport-aware pairing code. Automatic Iroh discovery
/// needs no QR. The displayed code never expires and is never regenerated on a
/// timer; Refresh Code re-mints on demand.
///
/// Reads auth state from the app's shared ``CmuxAuthRuntime/AuthCoordinator``
/// (via `AppDelegate`); sign-in routes through the shared ``HostAccountFlow``
/// and completion is observed by the view through observable auth state.
@MainActor
@Observable
final class MobilePairingModel {
    /// The pairing window's render state.
    enum State: Equatable {
        /// Resolving auth/listener state before anything is shown.
        case loading
        /// The Mac is not signed in; pairing can't be authorized yet.
        case signedOut
        /// Signed in; bringing the listener up and minting the first ticket.
        case preparing
        /// A ticket is ready to display.
        case ready(Ready)
        /// A phone has attached to the listener; show a paired/success state
        /// instead of the QR + spinner. Carries the state to restore when the
        /// connection count falls back to the baseline (the QR waiting state,
        /// or the Iroh-only waiting state when no Tailscale route exists).
        indirect case connected(from: State)
        /// No phone-reachable Tailscale route is available yet. Carries the
        /// live Iroh registration state so the window's Iroh tab keeps
        /// working while Tailscale QR pairing is unavailable.
        case needsReachableTransport(reachableViaIroh: Bool)
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        /// The `cmux-ios://attach?...` URL encoded into the QR code.
        let attachURL: String
        /// Reachable Tailscale `host:port` routes represented by the code.
        let tailscaleLines: [String]
        /// Reachable LAN `host:port` routes represented by the code.
        let lanLines: [String]
        /// The best route for manual phone entry, behind the "Copy IP" and
        /// "Copy Port" buttons. `nil` when no phone-dialable route exists.
        let manualEntry: CmxManualPairingEntry?
        /// Whether this Mac's Iroh endpoint is registered, so signed-in
        /// iPhones can discover it automatically without any QR.
        let reachableViaIroh: Bool

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }

        /// The same ticket with its route-derived diagnostics recomputed from
        /// a fresh host status. The displayed `attachURL` is intentionally
        /// kept: the code on screen is never regenerated behind the user's
        /// back; Refresh Code re-mints on demand.
        func updatingRoutes(_ routes: [CmxAttachRoute]) -> Ready {
            Ready(
                attachURL: attachURL,
                tailscaleLines: MobilePairingModel.tailscaleLines(routes),
                lanLines: MobilePairingModel.lanLines(routes),
                manualEntry: CmxManualPairingEntry.best(in: routes),
                reachableViaIroh: MobilePairingModel.hasIrohRoute(routes)
            )
        }
    }

    struct PairingRoutePlan: Equatable, Sendable {
        let disclosureMode: CmxPairingRouteDisclosureMode

        static func make(routes: [CmxAttachRoute]) -> PairingRoutePlan? {
            if routes.contains(where: MobilePairingModel.isPhoneReachableTailscaleRoute) {
                return PairingRoutePlan(
                    disclosureMode: .legacyPrivateNetworkCompatibility
                )
            }
            // A current iOS client can bootstrap LAN Only from an identity-only
            // Iroh code: the authenticated broker then supplies the LAN hint to
            // the encrypted session. Older clients never see a new `.lan` route
            // kind in their compatibility QR.
            guard routes.contains(where: { $0.kind == .iroh }),
                  routes.contains(where: { $0.kind == .lan }) else {
                return nil
            }
            return PairingRoutePlan(disclosureMode: .irohIdentityOnly)
        }
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .loading
    /// The signed-in account email, shown in the checklist. `nil` when signed out.
    private(set) var signedInEmail: String?
    /// Exact iOS apps this Mac build can intentionally address.
    let availableIOSAppTargets: [MobileIOSAppTarget]
    /// The exact iOS app addressed by newly minted QR codes.
    private(set) var selectedIOSAppTarget: MobileIOSAppTarget

    private let host: MobileHostService
    private let ticketTTL: TimeInterval
    private let iosAppTargetStore: MobileIOSPairingTargetStore
    /// Observes host status while a code is shown and tracks new connections.
    /// Cancelled on each refresh.
    private var connectionObservationTask: Task<Void, Never>?
    /// Bumped on each ``refresh()`` so a slower in-flight run (the UI fires
    /// refresh from several places) can't overwrite a newer result with a stale
    /// ticket. Each run captures its value and bails after an `await` if superseded.
    private var refreshGeneration = 0

    /// Creates a pairing model.
    ///
    /// - Parameters:
    ///   - host: The Mac-side pairing host service, or `nil` to use the shared
    ///     instance. (Resolved in the `@MainActor` init body rather than as a
    ///     default argument, since default args are evaluated nonisolated and
    ///     `MobileHostService.shared` is main-actor isolated.)
    ///   - ticketTTL: Lifetime of the minted attach token in seconds. Defaults
    ///     to 600. Covers only the RPC/v1 fallback token the mint produces as a
    ///     side effect; the displayed Tailscale QR carries no token and never
    ///     expires.
    init(host: MobileHostService? = nil, ticketTTL: TimeInterval = 600) {
        self.host = host ?? .shared
        self.ticketTTL = ticketTTL
        let targetStore = MobileIOSPairingTargetStore()
        iosAppTargetStore = targetStore
        let targets = targetStore.availableNamespaces.map { namespace in
            MobileIOSAppTarget(
                bundleIdentifier: namespace.bundleIdentifier,
                displayName: Self.targetDisplayName(
                    bundleIdentifier: namespace.bundleIdentifier
                )
            )
        }
        availableIOSAppTargets = targets
        selectedIOSAppTarget = targets.first {
            $0.bundleIdentifier
                == targetStore.selectedNamespace?.bundleIdentifier
        } ?? targets[0]
    }

    private var coordinator: AuthCoordinator? { AppDelegate.shared?.auth?.coordinator }

    /// Selects one exact iOS app and regenerates the pairing code for it.
    func selectIOSAppTarget(_ target: MobileIOSAppTarget) async {
        guard availableIOSAppTargets.contains(target),
              selectedIOSAppTarget != target,
              let namespace = MobileIOSAppNamespace(
                  bundleIdentifier: target.bundleIdentifier
              ),
              iosAppTargetStore.select(namespace) else {
            return
        }
        selectedIOSAppTarget = target
        MacPairedMacBackupPublisher.shared.pairingTargetDidChange(
            routes: host.statusSnapshot().routes
        )
        await refresh()
    }

    /// Re-evaluates sign-in state and, when signed in, brings the listener up
    /// and mints a fresh attach ticket. Safe to call repeatedly (Refresh button,
    /// or the view re-running it when auth state settles).
    func refresh() async {
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
        refreshGeneration &+= 1
        let generation = refreshGeneration
        state = .loading
        guard let coordinator else {
            state = .failed(
                String(
                    localized: "mobile.pairing.error.listenerOffline",
                    defaultValue: "Could not start the pairing listener on this Mac."
                )
            )
            return
        }
        await coordinator.awaitBootstrapped()
        guard generation == refreshGeneration else { return }
        guard coordinator.isAuthenticated else {
            signedInEmail = nil
            state = .signedOut
            return
        }
        signedInEmail = coordinator.currentUser?.primaryEmail
        state = .preparing
        enablePairingHost()
        let status = await host.ensureListeningAndReady()
        guard generation == refreshGeneration else { return }
        guard status.isRunning else {
            // Show localized copy, not the raw NWListener error string.
            state = .failed(
                String(
                    localized: "mobile.pairing.error.listenerOffline",
                    defaultValue: "Could not start the pairing listener on this Mac."
                )
            )
            return
        }
        guard let routePlan = PairingRoutePlan.make(routes: status.routes) else {
            state = .needsReachableTransport(
                reachableViaIroh: Self.hasIrohRoute(status.routes)
            )
            observeHostStatus()
            return
        }
        do {
            let payload = try await host.createAttachTicket(
                workspaceID: "",
                terminalID: nil,
                ttl: ticketTTL,
                routeDisclosureMode: routePlan.disclosureMode,
                // This QR is displayed for a physical phone. Selecting the
                // target makes mixed Iroh/LAN/Tailscale snapshots use the
                // lossless physical-device grammar instead of the legacy
                // Tailscale-only URL, so a later pinned mode has every route.
                target: .physicalDevice,
                pairingURLScheme: selectedIOSAppTarget.pairingURLScheme
            )
            guard generation == refreshGeneration else { return }
            guard let attachURL = payload["attach_url"] as? String, !attachURL.isEmpty else {
                state = .failed(
                    String(
                        localized: "mobile.pairing.error.noTicket",
                        defaultValue: "Could not generate a pairing code. Try again."
                    )
                )
                return
            }
            state = .ready(
                Ready(
                    attachURL: attachURL,
                    tailscaleLines: Self.tailscaleLines(status.routes),
                    lanLines: Self.lanLines(status.routes),
                    manualEntry: CmxManualPairingEntry.best(in: status.routes),
                    reachableViaIroh: Self.hasIrohRoute(status.routes)
                )
            )
            observeHostStatus()
        } catch MobileAttachTicketStoreError.noRoutes,
                MobileAttachTicketStoreError.routeUnavailable,
                MobileAttachTicketStoreError.invalidAttachURL {
            state = .needsReachableTransport(
                reachableViaIroh: Self.hasIrohRoute(host.statusSnapshot().routes)
            )
            observeHostStatus()
        } catch {
            state = .failed(
                String(
                    localized: "mobile.pairing.error.noTicket",
                    defaultValue: "Could not generate a pairing code. Try again."
                )
            )
        }
    }

    private static func targetDisplayName(
        bundleIdentifier: String
    ) -> String {
        switch bundleIdentifier {
        case "com.cmux.app":
            return String(
                localized: "mobile.pairing.target.appStore",
                defaultValue: "cmux"
            )
        case "dev.cmux.app.beta":
            return String(
                localized: "mobile.pairing.target.beta",
                defaultValue: "cmux BETA"
            )
        case "dev.cmux.app.internal":
            return String(
                localized: "mobile.pairing.target.internal",
                defaultValue: "cmux INTERNAL"
            )
        case "dev.cmux.app.demo":
            return String(
                localized: "mobile.pairing.target.demo",
                defaultValue: "cmux DEMO"
            )
        default:
            let format = String(
                localized: "mobile.pairing.target.dev",
                defaultValue: "cmux DEV %@"
            )
            let tag = bundleIdentifier.split(separator: ".").last ?? ""
            return String(format: format, locale: .current, String(tag))
        }
    }

    /// Cancels the connection observation. Call when the window closes.
    ///
    /// There is deliberately no timer to cancel: the displayed code never
    /// expires and is never regenerated behind the user's back. If a
    /// Tailscale address changes while the window sits open, the Refresh Code
    /// button re-mints on demand.
    func stopObserving() {
        // Invalidate any pending generation-guarded work (e.g. the observer's
        // spawned re-mint) so nothing revives the pairing host after close.
        refreshGeneration &+= 1
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
    }

    /// Watches the mobile host's status while the window is open: flips
    /// waiting states to `.connected` (and back) as phones attach and detach,
    /// keeps the route-derived transport diagnostics fresh, and re-mints when
    /// a Tailscale route first appears in the no-route state. Cancelled and
    /// superseded on each ``refresh()`` via the generation guard, and on
    /// ``stopObserving()``.
    private func observeHostStatus() {
        connectionObservationTask?.cancel()
        let generation = refreshGeneration
        // Connections already present when this code is displayed (another phone
        // is attached, or we are pairing an additional device). Only a NEW
        // connection above this baseline means "this freshly minted QR was
        // scanned"; without the baseline, opening the window while a phone is
        // already connected would falsely jump to "connected" before the new
        // ticket is ever used, which also makes pairing an additional device
        // impossible (the QR would hide immediately).
        let baseline = host.statusSnapshot().activeConnectionCount
        connectionObservationTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.host.statusUpdates() {
                if Task.isCancelled { return }
                guard generation == self.refreshGeneration else { return }
                let next = Self.statusTransition(
                    from: self.state,
                    routes: status.routes,
                    activeConnectionCount: status.activeConnectionCount,
                    baselineConnectionCount: baseline
                )
                if next != self.state {
                    self.state = next
                }
                // A Tailscale route appearing in the no-route state is the one
                // change a state edit can't express: the QR needs a fresh mint.
                if case .needsReachableTransport = self.state,
                   PairingRoutePlan.make(routes: status.routes) != nil {
                    Task { @MainActor [weak self] in
                        // Re-check the generation at execution time: a window
                        // close (stopObserving) or a newer refresh must not
                        // let this pending re-mint revive the pairing host.
                        guard let self, generation == self.refreshGeneration else { return }
                        await self.refresh()
                    }
                    return
                }
            }
        }
    }

    /// Computes the next render state from a host status event. Pure, so the
    /// transitions are unit tested without a live host.
    ///
    /// A connection *above* the `baselineConnectionCount` captured when the
    /// waiting state was entered (a phone that attached afterwards) flips
    /// `.ready` and `.needsReachableTransport` to `.connected`; dropping back
    /// to the baseline restores the prior waiting state. Waiting states also
    /// absorb route changes so the transport diagnostics stay live: the Iroh
    /// flag, the Tailscale lines, and the manual entry follow `routes`, while
    /// the displayed `attachURL` is deliberately never regenerated here (the
    /// code on screen never changes behind the user's back; Refresh Code
    /// re-mints on demand).
    static func statusTransition(
        from current: State,
        routes: [CmxAttachRoute],
        activeConnectionCount: Int,
        baselineConnectionCount: Int
    ) -> State {
        let connected = activeConnectionCount > baselineConnectionCount
        switch current {
        case let .ready(ready) where connected:
            return .connected(from: .ready(ready.updatingRoutes(routes)))
        case let .ready(ready):
            return .ready(ready.updatingRoutes(routes))
        case .needsReachableTransport where connected:
            return .connected(
                from: .needsReachableTransport(
                    reachableViaIroh: hasIrohRoute(routes)
                )
            )
        case .needsReachableTransport:
            return .needsReachableTransport(reachableViaIroh: hasIrohRoute(routes))
        case let .connected(prior) where !connected:
            return statusTransition(
                from: prior,
                routes: routes,
                activeConnectionCount: activeConnectionCount,
                baselineConnectionCount: baselineConnectionCount
            )
        case .connected:
            return current
        default:
            return current
        }
    }

    private func enablePairingHost() {
        // Never force the listener on under a managed remote-control disable.
        guard MobileRemoteControlPolicy.isEnabled else { return }
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    /// Whether this Mac's Iroh endpoint is registered in `routes`.
    private nonisolated static func hasIrohRoute(_ routes: [CmxAttachRoute]) -> Bool {
        routes.contains { $0.kind == .iroh }
    }

    /// Whether `route` can serve the legacy compatibility QR: a Tailscale route
    /// that does not point back at this Mac. LAN routes remain visible in the
    /// modern status/UI payloads, but the legacy grammar cannot be decoded by
    /// older iOS clients that predate the `.lan` route kind.
    private nonisolated static func isPhoneReachableTailscaleRoute(
        _ route: CmxAttachRoute
    ) -> Bool {
        route.kind == .tailscale && !CmxLoopbackHost().matches(route)
    }

    private nonisolated static func tailscaleLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return "\(host):\(port)"
        }
    }

    private nonisolated static func lanLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            guard route.kind == .lan,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return "\(host):\(port)"
        }
    }
}
