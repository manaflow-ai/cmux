import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth
import os

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

extension Notification.Name {
    static let mobileHostEventSubscriptionsDidChange = Notification.Name(
        "cmux.mobileHostEventSubscriptionsDidChange"
    )

    /// Posted whenever the mobile pairing host's observable status changes:
    /// the listener binds or stops, the bound port changes, or the active
    /// connection count changes. The Settings host adapter bridges this to an
    /// `AsyncStream` so the Mobile settings section can show the live bound
    /// port and connection count without polling.
    static let mobileHostStatusDidChange = Notification.Name(
        "cmux.mobileHostStatusDidChange"
    )
}

private final class MobileHostConnectionRegistry: @unchecked Sendable {
    static let shared = MobileHostConnectionRegistry()

    private let lock = NSLock()
    private var connections: [UUID: MobileHostConnection] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    func insert(_ connection: MobileHostConnection, id: UUID, limit: Int) -> Bool {
        lock.lock()
        guard connections.count < limit else {
            lock.unlock()
            return false
        }
        connections[id] = connection
        lock.unlock()
        // Notify after the authoritative count actually changes (this registry
        // backs `MobileHostServiceStatus.activeConnectionCount`), so the Mobile
        // settings diagnostics reflect the real count rather than a stale one.
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        return true
    }

    func remove(id: UUID) {
        lock.lock()
        let didRemove = connections.removeValue(forKey: id) != nil
        lock.unlock()
        if didRemove {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
    }

    func removeAll() -> [MobileHostConnection] {
        lock.lock()
        let values = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        if !values.isEmpty {
            NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
        }
        return values
    }

    /// Snapshot of current connections — caller fans out event delivery
    /// without holding the registry lock across `await`.
    func snapshot() -> [MobileHostConnection] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connections.values)
    }
}

private enum MobileHostPublicStatusCache {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var routes: [CmxAttachRoute] = []

    static func update(routes nextRoutes: [CmxAttachRoute]) {
        lock.lock()
        routes = nextRoutes
        lock.unlock()
        NotificationCenter.default.post(name: .mobileHostStatusDidChange, object: nil)
    }

    static func result(includeIdentity: Bool = false) -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = routes
        lock.unlock()
        let routesPayload = cachedRoutes.map(\.mobileHostJSONObject)
        return .ok(
            includeIdentity
                ? MobileHostService.identityStatusPayload(routesPayload: routesPayload)
                : MobileHostService.publicStatusPayload(routesPayload: routesPayload)
        )
    }
}

/// Moved to ``CMUXMobileCore.MobileHostServiceStatus`` (a pure `Sendable` value).
/// Kept as an app-side typealias so this file and `HostSettingsActions` consumers
/// stay byte-identical.
typealias MobileHostServiceStatus = CMUXMobileCore.MobileHostServiceStatus

@MainActor
final class MobileHostService {
    static let shared = MobileHostService()
    nonisolated private static let maximumActiveConnectionCount = 10

    /// The single shape every public `mobile.host.status` reply uses (the
    /// public-status cache, the network status gate, and
    /// `TerminalController`'s no-private-metadata branch), so the fields
    /// cannot drift. Identity-free: routes, fidelity, and capabilities are a
    /// reachability probe any peer may ask for, but the Mac's stable identity
    /// (`mac_device_id`, `mac_display_name`) is never on this unauthenticated
    /// surface — see ``networkStatusResult(for:)`` for the verified-caller
    /// reply that carries it.
    nonisolated static func publicStatusPayload(routesPayload: [[String: Any]]) -> [String: Any] {
        [
            "routes": routesPayload,
            "terminal_fidelity": "render_grid",
            "capabilities": mobileHostCapabilities,
        ]
    }

    /// `publicStatusPayload` plus the Mac's identity, for a caller that has
    /// proven same-account Stack ownership. The pairing QR no longer carries
    /// the display name or the device id, so this reply is where a freshly
    /// paired phone learns what to call this Mac and which paired-Mac record
    /// the connection belongs to.
    nonisolated static func identityStatusPayload(routesPayload: [[String: Any]]) -> [String: Any] {
        var payload = publicStatusPayload(routesPayload: routesPayload)
        payload["mac_device_id"] = MobileHostIdentity.deviceID()
        if let displayName = MobileHostIdentity.displayName() {
            payload["mac_display_name"] = displayName
        }
        let build = MobileHostBuildIdentity.current()
        if let appVersion = build.appVersion {
            payload["mac_app_version"] = appVersion
        }
        if let appBuild = build.appBuild {
            payload["mac_app_build"] = appBuild
        }
        return payload
    }

    /// The `mobile.host.status` reply for a network caller.
    ///
    /// Status is the one unauthenticated verb (a phone probes reachability
    /// before it has anything to present), so a tokenless request gets the
    /// cached identity-free payload without touching the main actor or the
    /// Stack verifier — the DoS posture of the public probe is unchanged, and
    /// an arbitrary process that can reach the port learns nothing that
    /// identifies or fingerprints this Mac. A request that does present the
    /// owner's same-account Stack token (the iOS client attaches it to status
    /// whenever it has one) is verified and answered with the Mac's identity,
    /// which is what a freshly QR-paired phone needs to key its paired-Mac
    /// record. A token that fails verification degrades to the identity-free
    /// payload rather than an error: reachability stays observable, and the
    /// authorized verbs that follow surface the auth failure properly.
    /// Verification goes through the same gate as the authorized verbs
    /// (``verifiedStackCaller(for:)``), so a DEBUG dev-token client that can
    /// list workspaces also sees identity.
    ///
    /// Because status is unauthenticated, the network verifications a
    /// token-bearing status request can trigger are bounded: an
    /// already-verified token answers from the verifier's cache, and
    /// cache-miss lookups are capped by
    /// ``MobileHostStatusVerificationLimiter`` (over the cap the reply
    /// degrades to identity-free and the phone's identity-recovery retry
    /// picks it up later). A flood of unique garbage tokens therefore cannot
    /// queue unbounded Stack lookups behind this verb.
    nonisolated static func networkStatusResult(for request: MobileHostRPCRequest) async -> MobileHostRPCResult {
        let trimmedToken = request.auth?.stackAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedToken?.isEmpty == false else {
            return MobileHostPublicStatusCache.result(includeIdentity: false)
        }
        let verified = await MobileHostService.shared.verifiedStackCaller(for: request)
        if !verified {
            mobileHostLog.error("mobile host status identity withheld: stack verification failed")
        }
        return MobileHostPublicStatusCache.result(includeIdentity: verified)
    }

    private let callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-listener")
    private let routeResolver = MobileRouteResolver()
    private let ticketStore = MobileAttachTicketStore()
    nonisolated private let ticketAuthorizationResolver = MobileAttachTicketAuthorizationResolver()
    /// Owns the per-topic subscription refcounts and posts
    /// `.mobileHostEventSubscriptionsDidChange`. Injected into every
    /// `MobileHostConnection` this service creates; the `nonisolated static`
    /// emit/has-subscribers forwarders read it through `shared`.
    nonisolated let eventSubscriptionRegistry = MobileHostEventSubscriptionRegistry()
    /// The process-wide request/connection activity counters that drive idle-quiet
    /// math. A single shared default (one per process, mirroring the previous
    /// `MobileHostRequestActivity` static-namespace state) injected here at the
    /// composition point; the `nonisolated static` begin/end and idle/quiet
    /// forwarders below read it so the existing call sites stay one token wide.
    nonisolated private static let sharedRequestActivity = MobileHostRequestActivityTracker()
    nonisolated let requestActivity: MobileHostRequestActivityTracker = MobileHostService.sharedRequestActivity

    /// True while any mobile request is being served. Forwards to the shared
    /// ``MobileHostRequestActivityTracker``.
    nonisolated static var hasActiveRequest: Bool { sharedRequestActivity.hasActiveRequest }

    /// Forwards to ``MobileHostRequestActivityTracker/hasRecentActivity(within:)``
    /// on the shared activity tracker.
    nonisolated static func hasRecentActivity(within interval: TimeInterval) -> Bool {
        sharedRequestActivity.hasRecentActivity(within: interval)
    }

    /// Forwards to ``MobileHostRequestActivityTracker/quietDelay(for:)`` on the
    /// shared activity tracker.
    nonisolated static func quietDelay(for interval: TimeInterval) -> TimeInterval {
        sharedRequestActivity.quietDelay(for: interval)
    }

    /// Forwards to ``MobileHostRequestActivityTracker/beginConnection()``.
    nonisolated static func beginConnection() { sharedRequestActivity.beginConnection() }

    /// Forwards to ``MobileHostRequestActivityTracker/endConnection()``.
    nonisolated static func endConnection() { sharedRequestActivity.endConnection() }

    /// Forwards to ``MobileHostRequestActivityTracker/beginRequest()``.
    nonisolated static func beginRequest() { sharedRequestActivity.beginRequest() }

    /// Forwards to ``MobileHostRequestActivityTracker/endRequest()``.
    nonisolated static func endRequest() { sharedRequestActivity.endRequest() }

    #if DEBUG
    /// Forwards to ``MobileHostRequestActivityTracker/resetForTesting()``.
    nonisolated static func resetRequestActivityForTesting() { sharedRequestActivity.resetForTesting() }
    #endif
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var listenerUsesEphemeralFallback = false
    private var listenerPort: Int?
    /// The preferred port the active start-sequence targeted (regardless of an
    /// ephemeral fallback). Used to decide whether a settings change needs a
    /// restart. `nil` while stopped.
    private var appliedPreferredPort: Int?
    private var activeConnections: [UUID: MobileHostConnection] = [:]
    private var clientIDsByConnectionID: [UUID: Set<String>] = [:]
    private var lastErrorDescription: String?
    /// Watches for network path changes while the listener is bound, so the
    /// advertised route set (and the team device registry that
    /// ``DeviceRegistryClient`` mirrors it into) refreshes when the Mac moves
    /// networks or Tailscale flips, not only when the listener restarts.
    /// `nil` while stopped.
    private var pathMonitor: MobileHostNetworkPathMonitor?
    /// Injected once via `configure(auth:)` at app startup, before the
    /// listener starts accepting connections.
    private var auth: AuthCoordinator?
    private var readinessWaiters: [CheckedContinuation<MobileHostServiceStatus, Never>] = []
    private var readinessTimeoutTask: Task<Void, Never>?
    #if DEBUG
    private var debugAcceptedStackAuthToken: String?
    #endif

    /// Same-account Stack verification for the mobile data plane (cache +
    /// refresh-ahead + capped network lookups). App composition wires its two
    /// seams here: the local-user provider reads this service's auth graph, and
    /// the Stack client factory builds a per-token client over the app's
    /// `AuthEnvironment` credentials and a ``MobileHostAccessTokenStore``.
    private let stackAuthVerifier: MobileHostStackAuthVerifier

    private init() {
        self.stackAuthVerifier = MobileHostStackAuthVerifier(
            localUserIDProvider: { await MobileHostService.shared.currentAuthenticatedLocalUserID() },
            makeStackClient: { accessToken in
                StackClientApp(
                    projectId: AuthEnvironment.stackProjectID,
                    publishableClientKey: AuthEnvironment.stackPublishableClientKey,
                    baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
                    tokenStore: .custom(MobileHostAccessTokenStore(accessToken: accessToken)),
                    noAutomaticPrefetch: true
                )
            }
        )
    }

    /// Inject the auth dependency. Call once at the composition root.
    func configure(auth: AuthCoordinator) {
        self.auth = auth
    }

    /// The signed-in local user's id, awaiting launch session restore first so
    /// pairing checks can't race it. `nil` when signed out (or before the auth
    /// graph is configured), which the authorization policy rejects.
    func currentAuthenticatedLocalUserID() async -> String? {
        guard let auth else { return nil }
        await auth.awaitBootstrapped()
        guard auth.isAuthenticated else { return nil }
        return auth.currentUser?.id
    }

    /// This Mac's authenticated Stack email, or `nil` when signed out or before
    /// the auth graph is configured.
    ///
    /// The mobile data plane only accepts same-account connections, so the
    /// caller is this Mac's own Stack account. The privileged agent feedback
    /// sink (`dogfood.feedback.submit`) checks this email's domain at the trust
    /// boundary, so a crafted RPC from a non-privileged account is rejected
    /// regardless of which route the phone UI chose.
    func currentAuthenticatedLocalUserEmail() async -> String? {
        guard let auth else { return nil }
        await auth.awaitBootstrapped()
        guard auth.isAuthenticated else { return nil }
        return auth.currentUser?.primaryEmail
    }

    /// Fan out a server-pushed event to every connection subscribed to `topic`.
    /// Safe to call from any actor/queue.
    nonisolated func emitEvent(topic: String, payload: [String: Any]) {
        Self.emitEvent(topic: topic, payload: payload)
    }

    /// Static form for callers already on non-main queues or Sendable
    /// notification closures. This path only touches the connection registry,
    /// not actor-isolated listener state.
    nonisolated static func emitEvent(topic: String, payload: [String: Any]) {
        guard shared.eventSubscriptionRegistry.hasSubscribers(topic: topic) else {
            return
        }
        let connections = MobileHostConnectionRegistry.shared.snapshot()
        guard !connections.isEmpty else { return }
        #if DEBUG
        cmuxDebugLog("mobile.emit topic=\(topic) connections=\(connections.count)")
        #endif
        for connection in connections {
            Task {
                let delivered = await connection.sendEvent(topic: topic, payload: payload)
                #if DEBUG
                cmuxDebugLog("mobile.emit -> connection delivered=\(delivered) topic=\(topic)")
                #endif
            }
        }
    }

    nonisolated static func hasEventSubscribers(topic: String) -> Bool {
        shared.eventSubscriptionRegistry.hasSubscribers(topic: topic)
    }

    /// User-default key for the opt-in Mac-side iOS pairing listener.
    nonisolated static let listeningEnabledDefaultsKey = SettingCatalog().mobile.iOSPairingHost.userDefaultsKey

    /// Whether the mobile pairing host should bind a network listener at all.
    ///
    /// Defaults off in every build so macOS does not ask for Local Network
    /// permission until the user enables iOS pairing in Settings.
    nonisolated static var isListeningEnabled: Bool {
        isListeningEnabled(defaults: .standard)
    }

    #if DEBUG
    nonisolated private static var isRunningUnderXCTest: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCInjectBundle"] != nil
            || environment["XCInjectBundleInto"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true
    }
    #endif

    nonisolated static func isListeningEnabled(defaults: UserDefaults) -> Bool {
        if let override = defaults.object(forKey: listeningEnabledDefaultsKey) as? Bool {
            return override
        }
        return SettingCatalog().mobile.iOSPairingHost.defaultValue
    }

    /// User-default key for the preferred iOS pairing listener port.
    nonisolated static let portDefaultsKey = SettingCatalog().mobile.iOSPairingPort.userDefaultsKey

    /// The preferred TCP port the listener should try to bind, read from
    /// settings.
    ///
    /// Falls back to the catalog default (which mirrors
    /// `CmxMobileDefaults.defaultHostPort`) when unset or outside the valid
    /// `1...65535` range. The listener still falls back to an OS-assigned
    /// ephemeral port if this port is unavailable at bind time.
    nonisolated static func configuredPort(defaults: UserDefaults = .standard) -> Int {
        let fallback = SettingCatalog().mobile.iOSPairingPort.defaultValue
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return fallback
        }
        return (1...65535).contains(raw) ? raw : fallback
    }

    /// The port a settings change should reconcile the *running* listener to, or
    /// `nil` when the stored value is present but out of range.
    ///
    /// Distinguished from ``configuredPort(defaults:)`` so an invalid value the
    /// user is still editing (the field shows a warning) does not tear down a
    /// running listener and silently rebind it to the default port. Returns the
    /// catalog default when unset, the override when valid, and `nil` when the
    /// stored value is out of range.
    nonisolated static func resolvedDesiredPort(defaults: UserDefaults = .standard) -> Int? {
        guard let raw = defaults.object(forKey: portDefaultsKey) as? Int else {
            return SettingCatalog().mobile.iOSPairingPort.defaultValue
        }
        return (1...65535).contains(raw) ? raw : nil
    }

    /// Applies an explicitly-requested pairing port.
    ///
    /// Make-before-break: when a running listener must move to a different port, a
    /// candidate listener is bound on that port *first*; only if it actually binds
    /// is the old listener torn down and the candidate adopted. So an in-use port
    /// leaves the running listener and its connections untouched (no probe →
    /// rebind gap that could drop connections). Operates on `UserDefaults.standard`
    /// since it persists to and rebinds the live singleton listener.
    func applyConfiguredPort(_ port: Int) async -> MobileHostPortApplyOutcome {
        let defaults = UserDefaults.standard
        if let preBind = MobileHostPortApplyOutcome.preBind(
            enabled: Self.isListeningEnabled(defaults: defaults),
            currentBoundPort: listenerPort,
            requestedPort: port
        ) {
            switch preBind {
            case .invalid, .portInUse:
                break
            case .savedWhileDisabled, .applied:
                defaults.set(port, forKey: Self.portDefaultsKey)
            }
            return preBind
        }
        // A real bind is required (pairing on, valid port, different from bound).
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return .invalid }
        guard let candidate = await bindReadyCandidate(on: endpointPort, generation: UUID()) else {
            return .portInUse
        }
        adoptCandidateListener(candidate.listener, generation: candidate.generation, port: port)
        defaults.set(port, forKey: Self.portDefaultsKey)
        return .applied(port)
    }

    /// Binds a candidate `NWListener` on `endpointPort` while the current listener
    /// keeps running, returning it (with `generation`) once it reaches `.ready`,
    /// or `nil` when the port is unavailable. A bounded, cancellable deadline
    /// guarantees the call can't hang; on timeout/failure the candidate is torn
    /// down and `nil` returned, leaving the live listener untouched.
    private func bindReadyCandidate(on endpointPort: NWEndpoint.Port, generation: UUID) async -> (listener: NWListener, generation: UUID)? {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        let candidate: NWListener
        do {
            candidate = try NWListener(using: NWParameters(tls: nil, tcp: tcpOptions), on: endpointPort)
        } catch {
            return nil
        }
        let queue = callbackQueue
        let didBind: Bool = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            // One-shot resume guard + deadline holder (lock carve-out): the state
            // handler and the timeout race to resume the continuation exactly once.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let timeoutHolder = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
            let finish: @Sendable (Bool) -> Void = { ready in
                let alreadyResumed = resumed.withLock { state -> Bool in
                    if state { return true }
                    state = true
                    return false
                }
                guard !alreadyResumed else { return }
                timeoutHolder.withLock { task in
                    task?.cancel()
                    task = nil
                }
                continuation.resume(returning: ready)
            }
            candidate.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(true)
                case .failed, .cancelled:
                    finish(false)
                case let .waiting(error):
                    if error.isAddressUnavailable { finish(false) }
                default:
                    break
                }
            }
            // NWListener needs a newConnectionHandler set before `start()` or it
            // never reaches `.ready`; wiring the real accept path (with this
            // generation) also means no connection is dropped once it's adopted.
            candidate.newConnectionHandler = { connection in
                MobileHostService.beginConnection()
                Self.acceptConnectionOffMain(connection, generation: generation)
            }
            candidate.start(queue: queue)
            // Bounded, cancellable safety deadline (check-timeout carve-out) so an
            // unclassified/stuck listener state can never hang the Apply flow.
            let timeout = Task {
                try? await Task.sleep(for: .seconds(2))
                finish(false)
            }
            timeoutHolder.withLock { $0 = timeout }
        }
        guard didBind else {
            candidate.stateUpdateHandler = nil
            candidate.newConnectionHandler = nil
            candidate.cancel()
            return nil
        }
        return (candidate, generation)
    }

    /// Cuts over to a freshly-bound `candidate`: tears down the old listener and
    /// its connections (they reconnect on the new port), then adopts the candidate
    /// as the live listener, routes future state changes through the normal
    /// handler, and republishes routes.
    private func adoptCandidateListener(_ candidate: NWListener, generation: UUID, port: Int) {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        for connection in activeConnections.values {
            Task { await connection.close(reason: "pairing port changed") }
        }
        for connection in MobileHostConnectionRegistry.shared.removeAll() {
            Task { await connection.close(reason: "pairing port changed") }
        }
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()

        listener = candidate
        listenerGeneration = generation
        listenerUsesEphemeralFallback = false
        listenerPort = port
        appliedPreferredPort = port
        lastErrorDescription = nil
        // The candidate is already `.ready`; route only *future* states normally.
        candidate.stateUpdateHandler = { state in
            Task { @MainActor in
                MobileHostService.shared.handleListenerState(state, generation: generation)
            }
        }
        routeResolver.refreshTailscaleRoutes(onResolvedHosts: { [weak self] hosts in
            Task { @MainActor [weak self] in
                self?.updatePublicStatusRoutes(port: port, generation: generation, tailscaleHosts: hosts)
            }
        })
        MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: port).routes)
        startNetworkPathMonitorIfNeeded()
        drainReadinessWaiters()
    }

    func start() {
        guard Self.isListeningEnabled else {
            #if DEBUG
            if Self.canPublishRoutesWithoutListenerForXCTest(defaults: .standard) {
                publishRoutesWithoutListenerForXCTest()
                return
            }
            #endif
            mobileHostLog.info("mobile host listener disabled; not binding")
            return
        }
        guard listener == nil else {
            return
        }

        startListener(usePreferredPort: true)
    }

    #if DEBUG
    nonisolated private static func canPublishRoutesWithoutListenerForXCTest(defaults: UserDefaults) -> Bool {
        guard isRunningUnderXCTest else { return false }
        return defaults.object(forKey: listeningEnabledDefaultsKey) == nil
    }

    private func publishRoutesWithoutListenerForXCTest() {
        guard listener == nil else { return }
        let port = Self.configuredPort()
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listenerPort = port
        appliedPreferredPort = port
        lastErrorDescription = nil
        MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: port).routes)
        mobileHostLog.info("mobile host listener disabled; publishing XCTest routes without binding")
    }
    #endif

    private func startListener(usePreferredPort: Bool) {
        let desiredPort = Self.configuredPort()
        appliedPreferredPort = desiredPort
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            let nextListener = try makeListener(
                parameters: parameters,
                usePreferredPort: usePreferredPort,
                port: desiredPort
            )
            let generation = UUID()
            listenerGeneration = generation
            nextListener.stateUpdateHandler = { state in
                Task { @MainActor in
                    MobileHostService.shared.handleListenerState(state, generation: generation)
                }
            }
            nextListener.newConnectionHandler = { connection in
                MobileHostService.beginConnection()
                Self.acceptConnectionOffMain(connection, generation: generation)
            }
            listener = nextListener
            listenerUsesEphemeralFallback = !usePreferredPort
            listenerPort = nil
            nextListener.start(queue: callbackQueue)
            startNetworkPathMonitorIfNeeded()
        } catch {
            if usePreferredPort {
                mobileHostLog.info("mobile host preferred port unavailable before listener start, falling back to an ephemeral port")
                startListener(usePreferredPort: false)
                return
            }
            lastErrorDescription = String(describing: error)
            mobileHostLog.error("mobile host listener failed to start: \(String(describing: error), privacy: .public)")
            // No listener was registered, so no state callback will fire to drain
            // readiness waiters; resolve them now instead of waiting for the deadline.
            drainReadinessWaiters()
        }
    }

    private func makeListener(
        parameters: NWParameters,
        usePreferredPort: Bool,
        port: Int
    ) throws -> NWListener {
        if usePreferredPort,
           let rawPort = UInt16(exactly: port),
           let endpointPort = NWEndpoint.Port(rawValue: rawPort) {
            return try NWListener(using: parameters, on: endpointPort)
        }
        return try NWListener(using: parameters, on: .any)
    }

    func stop() {
        stopNetworkPathMonitor()
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
        appliedPreferredPort = nil
        for connection in activeConnections.values {
            Task { await connection.close(reason: "service stopped") }
        }
        for connection in MobileHostConnectionRegistry.shared.removeAll() {
            Task { await connection.close(reason: "service stopped") }
        }
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()
        eventSubscriptionRegistry.reset()
        MobileHostPublicStatusCache.update(routes: [])
        TerminalController.shared.clearAllMobileViewportReports(reason: "mobile.host.stopped")
        drainReadinessWaiters()
    }

    func statusSnapshot() -> MobileHostServiceStatus {
        let routes = listenerPort.map { routeResolver.routes(port: $0).routes } ?? []
        return makeStatus(routes: routes)
    }

    /// Emits the current ``MobileHostServiceStatus`` immediately, then a fresh
    /// snapshot every time the listener or active-connection set changes (driven by
    /// `.mobileHostStatusDidChange`). The in-app pairing window consumes this to flip
    /// from "waiting" to "connected" the instant a phone attaches; it is the same
    /// signal that backs the Mobile settings connection count. The stream ends when
    /// the consumer cancels its task.
    func statusUpdates() -> AsyncStream<MobileHostServiceStatus> {
        AsyncStream { continuation in
            // Bridge the notification through a Sendable `Void` signal so the
            // non-Sendable `Notification` never crosses into the MainActor drain.
            // Mirrors `HostSettingsActions.mobilePairingStatusUpdates()`.
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = MobileHostStatusObserverToken(
                NotificationCenter.default.addObserver(
                    forName: .mobileHostStatusDidChange,
                    object: nil,
                    queue: nil
                ) { _ in
                    signalContinuation.yield(())
                }
            )
            let drainTask = Task { @MainActor in
                continuation.yield(MobileHostService.shared.statusSnapshot())
                for await _ in signals {
                    if Task.isCancelled { break }
                    continuation.yield(MobileHostService.shared.statusSnapshot())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    /// Starts the pairing listener (if enabled and not already bound) and
    /// resolves once it can mint attach tickets, so the in-app pairing window
    /// can render a QR code without polling the listener state machine.
    ///
    /// Resolves immediately when the listener is already ready, or when pairing
    /// is disabled (the caller then renders an "off" state). Otherwise it awaits
    /// the next listener-state transition (`ready`, terminal `failed`, or
    /// `cancelled`) via a continuation, with a bounded safety deadline so the UI
    /// never hangs on a listener that never settles.
    func ensureListeningAndReady() async -> MobileHostServiceStatus {
        start()
        if listener == nil || listenerPort != nil {
            return statusSnapshot()
        }
        return await withCheckedContinuation { continuation in
            readinessWaiters.append(continuation)
            if readinessTimeoutTask == nil {
                // Bounded, cancellable deadline: a local NWListener normally
                // reaches `.ready` within milliseconds; this only guards a
                // never-settling listener. Cancelled on the normal drain path.
                readinessTimeoutTask = Task { @MainActor [weak self] in
                    try? await ContinuousClock().sleep(for: .seconds(6))
                    guard let self, !Task.isCancelled else { return }
                    self.drainReadinessWaiters()
                }
            }
        }
    }

    /// Resumes every pending ``ensureListeningAndReady()`` caller with the
    /// current status and clears the bounded readiness deadline.
    private func drainReadinessWaiters() {
        readinessTimeoutTask?.cancel()
        readinessTimeoutTask = nil
        guard !readinessWaiters.isEmpty else { return }
        let snapshot = statusSnapshot()
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: snapshot)
        }
    }

    private func makeStatus(routes: [CmxAttachRoute]) -> MobileHostServiceStatus {
        let isRunning = listener != nil && listenerPort != nil
        return MobileHostServiceStatus(
            isRunning: isRunning,
            port: listenerPort,
            configuredPort: Self.configuredPort(),
            // The actual bind outcome, not a recomputation from current defaults:
            // editing the preferred port before a restart must not flip this.
            usesEphemeralFallback: isRunning && listenerUsesEphemeralFallback,
            routes: routes,
            activeConnectionCount: MobileHostConnectionRegistry.shared.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    /// Reconcile the live listener with current settings (enable/disable and
    /// preferred-port changes). Safe to call on any settings change: it no-ops
    /// unless the enabled state or the configured port actually changed, so an
    /// unrelated `UserDefaults` write does not drop active iOS connections.
    ///
    /// Reads `UserDefaults.standard` because the live singleton listener binds
    /// against the app's real store; `start`/`restart` do the same, so there is
    /// no caller-supplied store to honor here.
    func syncToSettings() {
        let defaults = UserDefaults.standard
        // An invalid stored port (`resolvedDesiredPort == nil`, e.g. mid-edit)
        // must not restart a running listener. Treat it as "no change" by
        // reusing the applied port; a fresh start still binds the default via
        // `configuredPort()`.
        let desiredPort = Self.resolvedDesiredPort(defaults: defaults)
            ?? appliedPreferredPort
            ?? Self.configuredPort(defaults: defaults)
        switch MobileHostSyncDecision.decide(
            enabled: Self.isListeningEnabled(defaults: defaults),
            listenerRunning: listener != nil,
            desiredPort: desiredPort,
            appliedPort: appliedPreferredPort
        ) {
        case .noop:
            break
        case .start:
            start()
        case .stop:
            stop()
        case .restart:
            restart()
        }
    }

    private func restart() {
        stop()
        start()
    }

    nonisolated private static func acceptConnectionOffMain(
        _ connection: NWConnection,
        generation: UUID
    ) {
        Task.detached(priority: .userInitiated) {
            let canAccept = await MobileHostService.shared.canAcceptConnection(generation: generation)
            guard canAccept else {
                mobileHostLog.info("mobile host rejected stale listener connection")
                connection.cancel()
                MobileHostService.endConnection()
                return
            }

            #if !DEBUG
            // Release builds never advertise a loopback route (the 127.0.0.1
            // `debugLoopback` route is DEBUG-only, see `MobileRouteResolver`), so a
            // legitimate phone always reaches the Mac over the Tailscale interface.
            // A connection arriving on loopback in release can only be a local
            // process (or a browser that somehow framed the binary protocol), never
            // the real client, so refuse it outright. DEBUG keeps loopback so the
            // iOS Simulator (which reaches the Mac via 127.0.0.1) can still pair.
            if CmxLoopbackHost().matchesStrictLoopback(connection) {
                mobileHostLog.error("mobile host rejected loopback connection in release build")
                connection.cancel()
                MobileHostService.endConnection()
                return
            }
            #endif

            let id = UUID()
            let session = MobileHostConnection(
                id: id,
                connection: connection,
                authorizeRequest: { request in
                    if !MobileHostService.shared.ticketAuthorizationResolver.requiresAuthorization(method: request.method) {
                        return nil
                    }
                    return await MobileHostService.shared.authorizationError(for: request)
                },
                onAuthorizedRequest: { request in
                    guard let clientID = Self.clientID(from: request.params) else {
                        return
                    }
                    await MobileHostService.shared.recordClientID(clientID, for: id)
                },
                handleRequest: { request in
                    if request.method == "mobile.host.status" {
                        return await MobileHostService.networkStatusResult(for: request)
                    }
                    let result = await TerminalController.shared.mobileHostHandleRPC(request)
                    await MobileHostService.shared.recordCreatedResourcesIfNeeded(
                        request: request,
                        result: result
                    )
                    return result
                },
                onClose: { id in
                    MobileHostConnectionRegistry.shared.remove(id: id)
                    await MobileHostService.shared.removeConnection(id: id)
                },
                eventSubscriptionRegistry: MobileHostService.shared.eventSubscriptionRegistry
            )
            guard MobileHostConnectionRegistry.shared.insert(
                session,
                id: id,
                limit: Self.maximumActiveConnectionCount
            ) else {
                mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
                connection.cancel()
                MobileHostService.endConnection()
                return
            }
            await session.start()
        }
    }

    private func canAcceptConnection(generation: UUID) -> Bool {
        listener != nil && generation == listenerGeneration
    }

    func createAttachTicket(
        workspaceID: String,
        terminalID: String?,
        ttl: TimeInterval,
        routeID: String? = nil,
        routeKind: String? = nil
    ) async throws -> [String: Any] {
        let routes: [CmxAttachRoute]
        if let listenerPort {
            routes = routeResolver.routes(port: listenerPort).routes
        } else {
            routes = []
        }
        let selectedRoutes: [CmxAttachRoute]
        do {
            selectedRoutes = try ticketAuthorizationResolver.filteredRoutes(
                routes,
                routeID: routeID,
                routeKind: routeKind
            )
        } catch MobileAttachTicketRouteSelectionError.routeUnavailable {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        let ticket = try ticketStore.createTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            routes: selectedRoutes,
            ttl: ttl,
            macUserEmail: await currentAuthenticatedLocalUserEmail(),
            macUserID: await currentAuthenticatedLocalUserID(),
            macPairingCompatibilityVersion: CmxMobileDefaults.pairingCompatibilityVersion,
            macAppVersion: MobileHostBuildIdentity.current().appVersion,
            macAppBuild: MobileHostBuildIdentity.current().appBuild
        )
        return try ticketStore.payload(for: ticket)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard listener != nil, generation == listenerGeneration else {
            connection.cancel()
            MobileHostService.endConnection()
            return
        }
        guard activeConnections.count < Self.maximumActiveConnectionCount else {
            mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
            connection.cancel()
            MobileHostService.endConnection()
            return
        }

        let id = UUID()
        let session = MobileHostConnection(
            id: id,
            connection: connection,
            authorizeRequest: { request in
                await MobileHostService.shared.authorizationError(for: request)
            },
            onAuthorizedRequest: { request in
                if let clientID = Self.clientID(from: request.params) {
                    await MobileHostService.shared.recordClientID(clientID, for: id)
                }
            },
            handleRequest: { request in
                if request.method == "mobile.host.status" {
                    return await MobileHostService.networkStatusResult(for: request)
                }
                let result = await TerminalController.shared.mobileHostHandleRPC(request)
                await MobileHostService.shared.recordCreatedResourcesIfNeeded(
                    request: request,
                    result: result
                )
                return result
            },
            onClose: { id in
                await MobileHostService.shared.removeConnection(id: id)
            },
            eventSubscriptionRegistry: eventSubscriptionRegistry
        )
        activeConnections[id] = session
        Task { await session.start() }
    }

    private func removeConnection(id: UUID) {
        MobileHostConnectionRegistry.shared.remove(id: id)
        activeConnections.removeValue(forKey: id)
        // Drop this connection's sticky viewport reports so a disconnected
        // device stops pinning the shared grid (and its macOS viewport border
        // clears) even though it never sent an explicit clear.
        let clientIDs = clientIDsByConnectionID[id] ?? []
        clientIDsByConnectionID.removeValue(forKey: id)
        if !clientIDs.isEmpty {
            TerminalController.shared.clearMobileViewportReports(
                clientIDs: clientIDs,
                reason: "mobile.connection.closed"
            )
        }
        MobileHostService.endConnection()
    }

    private func recordClientID(_ clientID: String, for connectionID: UUID) {
        var clientIDs = clientIDsByConnectionID[connectionID] ?? []
        clientIDs.insert(clientID)
        clientIDsByConnectionID[connectionID] = clientIDs
    }

    private nonisolated static func clientID(from params: [String: Any]) -> String? {
        let trimmed = (params["client_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    func debugAuthorizationError(for request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        await authorizationError(for: request)
    }

    /// Whether `request`'s Stack token passes the DEBUG dev-token policy.
    /// Always `false` in release builds. Shared by the authorization gate and
    /// the status identity gate so a dev-token client is treated identically
    /// on both.
    private func devStackTokenAuthorized(_ request: MobileHostRPCRequest) -> Bool {
        #if DEBUG
        if let stackAccessToken = request.auth?.stackAccessToken {
            return MobileHostAccountAuthorizer().authorizeDevStackToken(
                providedToken: stackAccessToken,
                acceptedToken: debugAcceptedStackAuthToken
            )
        }
        #endif
        return false
    }

    /// Whether `request` presents credentials that pass the same Stack gate
    /// as the authorized verbs (including the DEBUG dev-token policy),
    /// independent of whether the method itself requires authorization. The
    /// status path uses this to decide if the caller may see the Mac's
    /// identity.
    ///
    /// Unlike ``authorizationError(for:)`` (whose verbs are authorized, so a
    /// caller burning a network verification is at least failing auth), this
    /// gate is reachable from the UNAUTHENTICATED status verb. It therefore
    /// answers from the verifier's cache when it can, and caps concurrent
    /// cache-miss network lookups: saturated means "withhold identity now",
    /// never an unbounded queue of attacker-minted token verifications. The
    /// legitimate client recovers via its identity-recovery retry once its
    /// token is cache-verified by the authorized verbs that follow connect.
    func verifiedStackCaller(for request: MobileHostRPCRequest) async -> Bool {
        if devStackTokenAuthorized(request) {
            return true
        }
        if let cachedVerdict = await stackAuthVerifier.cachedVerdict(stackAccessToken: request.auth?.stackAccessToken) {
            return cachedVerdict
        }
        guard await MobileHostStatusVerificationLimiter.shared.acquire() else {
            mobileHostLog.error("mobile host status identity withheld: verification limiter saturated")
            return false
        }
        let verified: Bool
        do {
            try await verifyStackAuthOffMainActor(auth: request.auth)
            verified = true
        } catch {
            verified = false
        }
        // Non-throwing actor call: runs even if this task was cancelled
        // mid-verification, so a slot can never leak.
        await MobileHostStatusVerificationLimiter.shared.release()
        return verified
    }

    private func authorizationError(for request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        guard ticketAuthorizationResolver.requiresAuthorization(method: request.method) else {
            return nil
        }
        // Stack auth is the SOLE authorization gate for the mobile data plane.
        // The attach ticket is route-discovery and workspace-selection only; it
        // never authorizes on its own. Every operation must present the Mac
        // owner's same-account Stack access token. Consequences: a leaked or
        // photographed QR is useless without the owner's signed-in account, and
        // pairing is bound to "who is signed in on this Mac" rather than a stored
        // ticket, so it survives Mac restarts and ticket expiry.
        if devStackTokenAuthorized(request) {
            return nil
        }
        do {
            try await verifyStackAuthOffMainActor(auth: request.auth)
            return nil
        } catch MobileHostAuthorizationError.accountMismatch {
            // The presented Stack token is valid but belongs to a different
            // account than the one signed in on this Mac. Surface a distinct code
            // so the client can drive a re-authentication flow into the right
            // account rather than showing a generic failure.
            mobileHostLog.error("mobile host authorization rejected: account mismatch method=\(request.method, privacy: .public)")
            return .failure(MobileHostRPCError(
                code: "account_mismatch",
                message: "Sign in with the account that owns this Mac to continue."
            ))
        } catch {
            mobileHostLog.error("mobile host authorization failed method=\(request.method, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(MobileHostRPCError(
                code: "unauthorized",
                message: "Mobile sync authorization failed."
            ))
        }
    }

    private func verifyStackAuthOffMainActor(auth: MobileHostRPCAuth?) async throws {
        let verifier = stackAuthVerifier
        let stackAccessToken = auth?.stackAccessToken
        try await Task.detached(priority: .utility) {
            try await verifier.verify(stackAccessToken: stackAccessToken)
        }.value
    }

    private func recordCreatedResourcesIfNeeded(
        request: MobileHostRPCRequest,
        result: MobileHostRPCResult
    ) {
        guard let attachToken = request.auth?.attachToken else { return }
        guard case let .ok(payload) = result,
              let object = payload as? [String: Any] else { return }

        switch request.method {
        case "workspace.create":
            ticketStore.recordCreatedResources(
                authToken: attachToken,
                workspaceID: object["created_workspace_id"] as? String,
                terminalID: nil
            )
        case "mobile.terminal.create", "terminal.create":
            ticketStore.recordCreatedResources(
                authToken: attachToken,
                workspaceID: nil,
                terminalID: object["created_terminal_id"] as? String
            )
        default:
            break
        }
    }

    /// Test seam mapping ``MobileAttachTicketAuthorizationResolver`` onto the
    /// host's client-facing `MobileHostRPCError`.
    ///
    /// The ticket-scoping policy lives in
    /// ``MobileAttachTicketAuthorizationResolver`` (CMUXMobileCore). This wrapper
    /// extracts the typed selection inputs from the `Any`-shaped RPC request, runs
    /// the resolver, and maps the typed ``MobileAttachTicketError`` back onto the
    /// host's RPC error so the unit suite can exercise the policy through the host.
    static func debugTicketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest,
        createdWorkspaceIDs: Set<String> = [],
        createdTerminalIDs: Set<String> = []
    ) -> MobileHostRPCError? {
        let resolver = MobileHostService.shared.ticketAuthorizationResolver
        let workspaceSelection = resolver.stringParamSelection(
            request.params,
            keys: ["workspace_id"]
        )
        let terminalSelection = resolver.stringParamSelection(
            request.params,
            keys: ["surface_id", "terminal_id", "tab_id"]
        )
        let error = resolver.authorizationError(
            authorization: MobileAttachTicketAuthorizationContext(
                ticket: ticket,
                createdWorkspaceIDs: createdWorkspaceIDs,
                createdTerminalIDs: createdTerminalIDs
            ),
            method: request.method,
            workspaceSelection: workspaceSelection,
            terminalSelection: terminalSelection,
            hasIgnoredAliasParameters: resolver.containsIgnoredAliasParameters(request.params)
        )
        guard let error else {
            return nil
        }
        return MobileHostRPCError(code: error.code, message: error.defaultMessage)
    }

    private func handleListenerState(_ state: NWListener.State, generation: UUID) {
        guard generation == listenerGeneration else {
            return
        }

        switch state {
        case .ready:
            listenerPort = listener?.port.map { Int($0.rawValue) }
            lastErrorDescription = nil
            if let listenerPort {
                routeResolver.refreshTailscaleRoutes(onResolvedHosts: { [weak self] hosts in
                    Task { @MainActor [weak self] in
                        self?.updatePublicStatusRoutes(
                            port: listenerPort,
                            generation: generation,
                            tailscaleHosts: hosts
                        )
                    }
                })
                MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: listenerPort).routes)
            } else {
                MobileHostPublicStatusCache.update(routes: [])
            }
            mobileHostLog.info("mobile host listener ready on port \(self.listenerPort ?? 0)")
            drainReadinessWaiters()
        case let .failed(error):
            handleListenerBindFailure(error: error, context: "failed after start")
        case .cancelled:
            listenerGeneration = UUID()
            listener = nil
            listenerUsesEphemeralFallback = false
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
            drainReadinessWaiters()
        case let .waiting(error):
            // A preferred-port bind blocked by another listener surfaces as
            // `.waiting(.posix(.EADDRINUSE))` rather than `.failed`, and NWListener
            // would otherwise wait forever; treat address-unavailable the same as
            // a failure so the ephemeral fallback (and bound-port warning) fire.
            if error.isAddressUnavailable {
                handleListenerBindFailure(error: error, context: "in use (waiting)")
            } else {
                listenerPort = nil
                MobileHostPublicStatusCache.update(routes: [])
            }
        case .setup:
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
        @unknown default:
            break
        }
    }

    /// Tears down a listener that could not bind its preferred port and, unless
    /// it was already on the ephemeral fallback, retries on an OS-assigned port.
    /// Shared by the `.failed` and `.waiting(addressUnavailable)` paths.
    private func handleListenerBindFailure(error: NWError, context: String) {
        lastErrorDescription = String(describing: error)
        MobileHostPublicStatusCache.update(routes: [])
        let shouldRetryWithEphemeralPort = !listenerUsesEphemeralFallback
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listenerGeneration = UUID()
        listener = nil
        listenerUsesEphemeralFallback = false
        listenerPort = nil
        if shouldRetryWithEphemeralPort {
            mobileHostLog.info("mobile host preferred port \(context, privacy: .public), falling back to an ephemeral port")
            startListener(usePreferredPort: false)
        } else {
            mobileHostLog.error("mobile host listener bind failed on ephemeral port: \(String(describing: error), privacy: .public)")
            // No retry left: unblock any readiness waiters (the retry path drains
            // them when the ephemeral listener reaches `.ready`).
            drainReadinessWaiters()
        }
    }

    private func updatePublicStatusRoutes(
        port: Int,
        generation: UUID,
        tailscaleHosts: [String]
    ) {
        guard generation == listenerGeneration, listenerPort == port else {
            return
        }
        MobileHostPublicStatusCache.update(
            routes: routeResolver.routes(port: port, tailscaleHosts: tailscaleHosts).routes
        )
    }

    // MARK: - Network path monitoring

    /// Begin republishing routes on network path changes (observation and
    /// dedup live in ``MobileHostNetworkPathMonitor``). Idempotent; runs for
    /// the lifetime of the listener and is stopped by ``stop()``.
    private func startNetworkPathMonitorIfNeeded() {
        guard pathMonitor == nil else { return }
        let monitor = MobileHostNetworkPathMonitor { [weak self] in
            self?.handleNetworkPathChange()
        }
        monitor.start(queue: callbackQueue)
        pathMonitor = monitor
    }

    private func stopNetworkPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func handleNetworkPathChange() {
        // The cached Tailscale hosts (and any in-flight resolution) may describe
        // the previous network; drop them on EVERY path observation so no later
        // refresh can be satisfied from, or raced by, old-path state. This must
        // happen before the no-port early return: the monitor's first
        // observation can land mid-bind, advancing its dedup baseline, and the
        // `.ready` publish that follows would otherwise be free to reuse a
        // TTL-fresh cache from the previous network with no further path
        // callback coming to correct it.
        routeResolver.invalidateResolvedTailscaleHostCache()
        guard let port = listenerPort else {
            // Mid-bind (no port yet): the `.ready` handler publishes against the
            // current path when the bind completes, and the invalidation above
            // guarantees it resolves freshly.
            return
        }
        let generation = listenerGeneration
        // Same two-phase publish as the listener-ready handler: immediate routes
        // from interface scan now, DNS-resolved hosts when they land.
        routeResolver.refreshTailscaleRoutes(onResolvedHosts: { [weak self] hosts in
            Task { @MainActor [weak self] in
                self?.updatePublicStatusRoutes(port: port, generation: generation, tailscaleHosts: hosts)
            }
        })
        MobileHostPublicStatusCache.update(routes: routeResolver.routes(port: port).routes)
    }
}


#if DEBUG
extension MobileHostService {
    func debugResetMobileLifecycleStateForTesting() {
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listenerPort = nil
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()
        requestActivity.resetForTesting()
        eventSubscriptionRegistry.resetForTesting()
    }

    func debugRecordClientIDForTesting(_ clientID: String, connectionID: UUID) {
        recordClientID(clientID, for: connectionID)
    }

    func debugRemoveConnectionForTesting(id: UUID) {
        removeConnection(id: id)
    }

    func debugTrackedClientIDsForTesting(connectionID: UUID) -> Set<String>? {
        clientIDsByConnectionID[connectionID]
    }

    func debugSetListenerStateForTesting(
        generation: UUID,
        usesEphemeralFallback: Bool,
        port: Int?
    ) {
        listenerGeneration = generation
        listenerUsesEphemeralFallback = usesEphemeralFallback
        listenerPort = port
    }

    func debugHandleListenerStateForTesting(_ state: NWListener.State, generation: UUID) {
        handleListenerState(state, generation: generation)
    }

    func debugListenerGenerationForTesting() -> UUID {
        listenerGeneration
    }

    func debugListenerPortForTesting() -> Int? {
        listenerPort
    }

    func debugListenerUsesEphemeralFallbackForTesting() -> Bool {
        listenerUsesEphemeralFallback
    }

    func debugConfigureAcceptedStackAuthTokenForTesting(_ token: String?) {
        debugAcceptedStackAuthToken = MobileHostAccountAuthorizer().normalizedDevToken(token)
    }

    func debugAcceptedStackAuthTokenForTesting() -> String? {
        debugAcceptedStackAuthToken
    }

    nonisolated static func debugHasEventSubscribersForTesting(topic: String) -> Bool {
        shared.eventSubscriptionRegistry.hasSubscribers(topic: topic)
    }

    nonisolated static func debugResetEventSubscriptionsForTesting() {
        shared.eventSubscriptionRegistry.resetForTesting()
    }
}
#endif
