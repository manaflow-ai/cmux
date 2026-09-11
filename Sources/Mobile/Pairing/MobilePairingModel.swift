import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in, then turns on the explicitly requested v2 IROH pairing host. v2 pairing
/// uses the signed-in account and device identity, so it has no QR or address
/// to display.
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
        /// Signed in; bringing the v2 IROH listener up.
        case preparing
        /// The v2 IROH listener is ready for the signed-in iPhone.
        case ready(Ready)
        /// A phone has attached to the listener; show a paired/success state.
        /// Carries the state to restore when the connection count falls back to
        /// the baseline.
        indirect case connected(from: State)
        /// Compatibility state retained for old callers while the v2 window is
        /// active. The v2 path does not publish direct or Tailscale routes.
        case needsReachableTransport(reachableViaIroh: Bool)
        /// The listener could not be started.
        case failed(String)
    }

    /// Pairing status. Legacy fields remain for source compatibility with old
    /// previews; v2 always leaves them empty and sets ``v2Only``.
    struct Ready: Equatable {
        /// Legacy attach URL. Empty for v2.
        let attachURL: String
        /// Legacy Tailscale routes. Empty for v2.
        let tailscaleLines: [String]
        /// Legacy manual route. `nil` for v2.
        let manualEntry: CmxManualPairingEntry?
        /// Whether this Mac's IROH endpoint is ready for the signed-in iPhone.
        let reachableViaIroh: Bool
        /// v2 pairing uses the authenticated IROH bootstrap and has no QR.
        let v2Only: Bool

        init(
            attachURL: String,
            tailscaleLines: [String],
            manualEntry: CmxManualPairingEntry?,
            reachableViaIroh: Bool,
            v2Only: Bool = false
        ) {
            self.attachURL = attachURL
            self.tailscaleLines = tailscaleLines
            self.manualEntry = manualEntry
            self.reachableViaIroh = reachableViaIroh
            self.v2Only = v2Only
        }

        /// Whether a legacy Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }

        /// Recomputes compatibility route diagnostics from host status. The v2
        /// pairing view does not use these legacy fields.
        func updatingRoutes(_ routes: [CmxAttachRoute]) -> Ready {
            Ready(
                attachURL: attachURL,
                tailscaleLines: MobilePairingModel.tailscaleLines(routes),
                manualEntry: CmxManualPairingEntry.best(in: routes),
                reachableViaIroh: MobilePairingModel.hasIrohRoute(routes),
                v2Only: v2Only
            )
        }
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

    /// Selects one exact iOS app for legacy compatibility previews.
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

    /// Re-evaluates sign-in state and, when signed in, brings the v2 listener
    /// up. Safe to call repeatedly when auth state settles.
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
        guard generation == refreshGeneration else { return }
        // v2 registration is performed by the authenticated IROH bootstrap
        // connection. The Mac never publishes a QR, Tailscale address, or
        // direct path to the server or pairing UI.
        state = .ready(
            Ready(
                attachURL: "",
                tailscaleLines: [],
                manualEntry: nil,
                reachableViaIroh: true,
                v2Only: true
            )
        )
        observeHostStatus()
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
    func stopObserving() {
        // Invalidate any pending generation-guarded work (e.g. the observer's
        // spawned re-mint) so nothing revives the pairing host after close.
        refreshGeneration &+= 1
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
    }

    /// Watches the mobile host's status while the window is open and flips
    /// waiting states to `.connected` as phones attach and detach.
    private func observeHostStatus() {
        connectionObservationTask?.cancel()
        let generation = refreshGeneration
        // Connections already present when this code is displayed establish the
        // baseline. Only a new connection above it changes the waiting state.
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
            }
        }
    }

    /// Computes the next render state from a host status event. Pure, so the
    /// transitions are unit tested without a live host.
    ///
    /// A connection above the captured baseline flips the waiting state to
    /// `.connected`; dropping back restores the prior waiting state.
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

    /// Whether `route` can serve a physical iPhone: a Tailscale route that does
    /// not point back at this Mac.
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
}
