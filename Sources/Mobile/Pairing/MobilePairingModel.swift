import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Observation

/// Drives the in-app iOS pairing window. Gates pairing on the Mac being signed
/// in (authorization is a Stack same-account check), then turns on the
/// pairing host, mints a short-lived attach ticket, and exposes the QR payload
/// plus Tailscale reachability for the view.
///
/// Reads auth state from the app's shared ``CmuxAuthRuntime/AuthCoordinator``
/// (via `AppDelegate`); the browser sign-in is fire-and-forget and completion
/// is observed by the view through the coordinator's `@Observable` state.
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
        /// The listener is up but there is no route a phone can reach (no
        /// Tailscale address on this Mac), so no ticket can be minted yet.
        case needsTailscale
        /// The listener could not be started or no ticket could be minted.
        case failed(String)
    }

    /// Status of one requirements-checklist row, derived from ``State``.
    /// Drives the shared status badge in ``MobilePairingView``: `needsAction`
    /// is the red "fix this" state, `complete` the green done state, and
    /// `pending` stays neutral while the step can't be evaluated yet.
    enum RequirementStatus: Equatable {
        /// The requirement is satisfied.
        case complete
        /// The requirement blocks pairing and the user must act.
        case needsAction
        /// Not yet known: still resolving, or gated behind an earlier step.
        case pending
    }

    /// A minted ticket ready for display.
    struct Ready: Equatable {
        /// The `cmux-ios://attach?...` URL encoded into the QR code.
        let attachURL: String
        /// The Mac's display name, shown above the code.
        let macName: String
        /// Reachable Tailscale `host:port` routes. Empty when Tailscale is not
        /// detected, in which case a real iPhone cannot reach this Mac.
        let tailscaleLines: [String]

        /// Whether at least one Tailscale route resolved.
        var reachableViaTailscale: Bool { !tailscaleLines.isEmpty }
    }

    /// The current render state, observed by ``MobilePairingView``.
    private(set) var state: State = .loading
    /// The signed-in account email, shown in the checklist. `nil` when signed out.
    private(set) var signedInEmail: String?
    /// Whether the coordinator reported an authenticated account on the last
    /// ``refresh()``. Tracked separately from ``signedInEmail`` because an
    /// authenticated account can lack a primary email.
    private(set) var isSignedIn = false

    private let host: MobileHostService
    private let ticketTTL: TimeInterval
    /// Re-mints the ticket shortly before it expires so the displayed QR is
    /// never stale. Cancelled on every refresh and when the window closes.
    private var autoRefreshTask: Task<Void, Never>?
    /// Observes the host's connection status while a code is shown, flipping the
    /// render state between `.ready` and `.connected`. Cancelled on each refresh.
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
    ///   - ticketTTL: Attach-ticket lifetime in seconds. Defaults to 600.
    init(host: MobileHostService? = nil, ticketTTL: TimeInterval = 600) {
        self.host = host ?? .shared
        self.ticketTTL = ticketTTL
    }

    private var coordinator: AuthCoordinator? { AppDelegate.shared?.auth?.coordinator }

    /// Re-evaluates sign-in state and, when signed in, brings the listener up
    /// and mints a fresh attach ticket. Safe to call repeatedly (Refresh button,
    /// or the view re-running it when auth state settles).
    func refresh() async {
        autoRefreshTask?.cancel()
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
            isSignedIn = false
            signedInEmail = nil
            state = .signedOut
            return
        }
        isSignedIn = true
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
        // No route a phone can reach (no Tailscale address on this Mac, and no
        // debug loopback in release): surface the Tailscale-missing guidance
        // instead of letting `createAttachTicket` throw a raw `noRoutes`.
        guard !status.routes.isEmpty else {
            state = .needsTailscale
            return
        }
        do {
            let payload = try await host.createAttachTicket(
                workspaceID: "",
                terminalID: nil,
                ttl: ticketTTL
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
                    macName: Self.macDisplayName,
                    tailscaleLines: Self.tailscaleLines(status.routes)
                )
            )
            scheduleExpiryRefresh()
            observeConnections()
        } catch MobileAttachTicketStoreError.noRoutes, MobileAttachTicketStoreError.routeUnavailable {
            state = .needsTailscale
        } catch {
            state = .failed(
                String(
                    localized: "mobile.pairing.error.noTicket",
                    defaultValue: "Could not generate a pairing code. Try again."
                )
            )
        }
    }

    /// Launches the Mac browser sign-in flow. Fire-and-forget; the view re-runs
    /// ``refresh()`` when the coordinator's auth state settles.
    func signIn() {
        state = .loading
        AppDelegate.shared?.auth?.browserSignIn.beginSignIn()
    }

    /// Cancels the pending expiry re-mint. Call when the window closes.
    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        connectionObservationTask?.cancel()
        connectionObservationTask = nil
    }

    /// Schedules a re-mint shortly before the current ticket's TTL elapses, so a
    /// delayed scan never hits an expired code.
    private func scheduleExpiryRefresh() {
        autoRefreshTask?.cancel()
        // Bounded, cancellable, duration-driven deadline (re-mint ~30s before
        // expiry). Not a poll; cancelled on the next refresh or on window close.
        let delay = max(1, ticketTTL - 30)
        autoRefreshTask = Task { [weak self] in
            try? await ContinuousClock().sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            await self.refresh()
        }
    }

    /// Watches the mobile host's connection status while a code is displayed and
    /// flips between `.ready` (QR shown, waiting) and `.connected` (a phone has
    /// attached). Cancelled and superseded on each ``refresh()`` via the generation
    /// guard, and on ``stopAutoRefresh()``.
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

    /// Status of the "Signed in to cmux" checklist row.
    var signInRequirement: RequirementStatus {
        Self.signInRequirementStatus(for: state, signedIn: isSignedIn)
    }

    /// Status of the Tailscale checklist row.
    var tailscaleRequirement: RequirementStatus {
        Self.tailscaleRequirementStatus(for: state)
    }

    /// Maps the render state onto the sign-in checklist row. A confirmed
    /// account always completes the step. Otherwise only an explicit
    /// `.signedOut` turns the row red; resolving states (and a failure before
    /// auth ever resolved) stay neutral. Pure, so the mapping is unit tested
    /// without a live coordinator.
    static func signInRequirementStatus(for state: State, signedIn: Bool) -> RequirementStatus {
        if signedIn { return .complete }
        switch state {
        case .signedOut:
            return .needsAction
        case .loading, .preparing, .ready, .connected, .needsTailscale, .failed:
            return .pending
        }
    }

    /// Maps the render state onto the Tailscale checklist row. Red only once
    /// we know the phone has no route (`.needsTailscale`, or a ticket minted
    /// without a Tailscale route); neutral while loading, signed out, or
    /// failed, where reachability hasn't been evaluated. Pure for unit tests.
    static func tailscaleRequirementStatus(for state: State) -> RequirementStatus {
        switch state {
        case .needsTailscale:
            return .needsAction
        case let .ready(ready), let .connected(ready):
            return ready.reachableViaTailscale ? .complete : .needsAction
        case .loading, .signedOut, .preparing, .failed:
            return .pending
        }
    }

    private func enablePairingHost() {
        UserDefaults.standard.set(true, forKey: MobileHostService.listeningEnabledDefaultsKey)
    }

    private static var macDisplayName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
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
