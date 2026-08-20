import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in (authorization is a Stack same-account check), then turns on the pairing
/// host and mints a Tailscale pairing code. Automatic Iroh discovery needs no
/// QR. The displayed Tailscale code never expires and is never regenerated on
/// a timer; Refresh Code re-mints on demand.
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
        /// instead of the QR + spinner.
        case connected(Ready)
        /// No phone-reachable Tailscale route is available yet.
        case needsReachableTransport
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        /// The `cmux-ios://attach?...` URL encoded into the QR code.
        let attachURL: String
        /// Reachable Tailscale `host:port` routes represented by the code.
        let tailscaleLines: [String]
        /// The best route for manual phone entry, behind the "Copy IP" and
        /// "Copy Port" buttons. `nil` when no phone-dialable route exists.
        let manualEntry: CmxManualPairingEntry?

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
    }

    struct PairingRoutePlan: Equatable, Sendable {
        let disclosureMode: CmxPairingRouteDisclosureMode

        static func make(routes: [CmxAttachRoute]) -> PairingRoutePlan? {
            guard routes.contains(
                where: MobilePairingModel.isPhoneReachableTailscaleRoute
            ) else { return nil }
            return PairingRoutePlan(
                disclosureMode: .legacyPrivateNetworkCompatibility
            )
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
            state = .needsReachableTransport
            observeRouteAvailability()
            return
        }
        do {
            let payload = try await host.createAttachTicket(
                workspaceID: "",
                terminalID: nil,
                ttl: ticketTTL,
                routeDisclosureMode: routePlan.disclosureMode,
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
                    manualEntry: CmxManualPairingEntry.best(in: status.routes)
                )
            )
            observeConnections()
        } catch MobileAttachTicketStoreError.noRoutes,
                MobileAttachTicketStoreError.routeUnavailable,
                MobileAttachTicketStoreError.invalidAttachURL {
            state = .needsReachableTransport
            observeRouteAvailability()
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

    /// Launches the Mac browser sign-in flow. Fire-and-forget; the view re-runs
    /// ``refresh()`` when the coordinator's auth state settles.
    func signIn() {
        state = .loading
        AppDelegate.shared?.auth?.browserSignIn.beginSignIn()
    }
    /// Cancels the connection observation. Call when the window closes.
    ///
    /// There is deliberately no timer to cancel: the displayed code never
    /// expires and is never regenerated behind the user's back. If a
    /// Tailscale address changes while the window sits open, the Refresh Code
    /// button re-mints on demand.
    func stopObserving() {
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
    }

    /// Watches the mobile host's connection status while a code is displayed and
    /// flips between `.ready` (QR shown, waiting) and `.connected` (a phone has
    /// attached). Cancelled and superseded on each ``refresh()`` via the generation
    /// guard, and on ``stopObserving()``.
    private func observeConnections() {
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
                self.state = Self.connectionTransition(
                    from: self.state,
                    activeConnectionCount: status.activeConnectionCount,
                    baselineConnectionCount: baseline
                )
            }
        }
    }

    /// Automatically replaces the temporary no-route state when a Tailscale
    /// route appears. This is event-driven by the host status cache.
    private func observeRouteAvailability() {
        connectionObservationTask?.cancel()
        let generation = refreshGeneration
        connectionObservationTask = Task { [weak self] in
            guard let self else { return }
            for await status in self.host.statusUpdates() {
                guard !Task.isCancelled,
                      generation == self.refreshGeneration else { return }
                guard PairingRoutePlan.make(routes: status.routes) != nil else {
                    continue
                }
                Task { @MainActor [weak self] in
                    await self?.refresh()
                }
                return
            }
        }
    }

    /// Computes the next render state from a connection-count change, relative to
    /// the `baselineConnectionCount` captured when the code was displayed. A
    /// connection *above* the baseline (a phone that attached after the QR was
    /// shown) flips a displayed ticket from `.ready` to `.connected`; dropping
    /// back to the baseline flips it back so the QR returns. All other states
    /// pass through unchanged. Pure, so the transition is unit tested without a
    /// live host.
    static func connectionTransition(
        from current: State,
        activeConnectionCount: Int,
        baselineConnectionCount: Int
    ) -> State {
        let connected = activeConnectionCount > baselineConnectionCount
        switch current {
        case let .ready(ready) where connected:
            return .connected(ready)
        case let .connected(ready) where !connected:
            return .ready(ready)
        default:
            return current
        }
    }

    private func enablePairingHost() {
        // Never force the listener on under a managed remote-control disable.
        guard MobileRemoteControlPolicy.isEnabled else { return }
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    /// Whether `route` can serve a physical iPhone: a Tailscale route that does
    /// not point back at this Mac.
    private nonisolated static func isPhoneReachableTailscaleRoute(
        _ route: CmxAttachRoute
    ) -> Bool {
        route.kind == .tailscale && !CmxLoopbackHost().matches(route)
    }

    private static func tailscaleLines(_ routes: [CmxAttachRoute]) -> [String] {
        routes.compactMap { route in
            guard route.kind == .tailscale,
                  case let .hostPort(host, port) = route.endpoint else {
                return nil
            }
            return "\(host):\(port)"
        }
    }
}
