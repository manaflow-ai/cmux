import CMUXMobileCore
import CmuxAuthRuntime
import CmuxSettings
import CryptoKit
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

private enum MobileHostEventSubscriptionTracker {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var topicCounts: [String: Int] = [:]

    static func hasSubscribers(topic: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return (topicCounts[topic] ?? 0) > 0
    }

    static func replace(previousTopics: Set<String>?, nextTopics: Set<String>?) {
        let changedTopics = updateCounts(previousTopics: previousTopics, nextTopics: nextTopics)
        guard !changedTopics.isEmpty else { return }
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": Array(changedTopics).sorted()]
        )
    }

    private static func updateCounts(previousTopics: Set<String>?, nextTopics: Set<String>?) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }

        var changedTopics = Set<String>()
        let allTopics = Set(previousTopics ?? []).union(nextTopics ?? [])
        let before = Dictionary(uniqueKeysWithValues: allTopics.map { ($0, topicCounts[$0] ?? 0) })

        for topic in previousTopics ?? [] {
            let nextCount = max(0, (topicCounts[topic] ?? 0) - 1)
            if nextCount == 0 {
                topicCounts.removeValue(forKey: topic)
            } else {
                topicCounts[topic] = nextCount
            }
        }
        for topic in nextTopics ?? [] {
            topicCounts[topic] = (topicCounts[topic] ?? 0) + 1
        }

        for topic in allTopics {
            let wasActive = (before[topic] ?? 0) > 0
            let isActive = (topicCounts[topic] ?? 0) > 0
            if wasActive != isActive {
                changedTopics.insert(topic)
            }
        }
        return changedTopics
    }

    static func reset() {
        lock.lock()
        topicCounts.removeAll()
        lock.unlock()
        NotificationCenter.default.post(
            name: .mobileHostEventSubscriptionsDidChange,
            object: nil,
            userInfo: ["topics": []]
        )
    }

    #if DEBUG
    static func resetForTesting() {
        reset()
    }
    #endif
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

enum MobileHostRequestActivity {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var activeRequestCount = 0
    private nonisolated(unsafe) static var activeConnectionCount = 0
    private nonisolated(unsafe) static var lastActivityUptime: TimeInterval = 0

    static var hasActiveRequest: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeRequestCount > 0
    }

    static func hasRecentActivity(within interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return true }
        guard lastActivityUptime > 0 else { return false }
        return ProcessInfo.processInfo.systemUptime - lastActivityUptime < interval
    }

    static func quietDelay(for interval: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0 else { return interval }
        guard lastActivityUptime > 0 else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastActivityUptime
        return max(0, interval - elapsed)
    }

    static func beginConnection() {
        lock.lock()
        activeConnectionCount += 1
        lock.unlock()
    }

    static func endConnection() {
        lock.lock()
        activeConnectionCount = max(0, activeConnectionCount - 1)
        lock.unlock()
    }

    static func beginRequest() {
        lock.lock()
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        activeRequestCount += 1
        lock.unlock()
    }

    static func endRequest() {
        lock.lock()
        activeRequestCount = max(0, activeRequestCount - 1)
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }

    #if DEBUG
    static func resetForTesting() {
        lock.lock()
        activeRequestCount = 0
        activeConnectionCount = 0
        lastActivityUptime = 0
        lock.unlock()
    }
    #endif
}

struct MobileHostServiceStatus {
    let isRunning: Bool
    let port: Int?
    /// The preferred port from settings the listener tried to bind.
    let configuredPort: Int
    /// True when the listener is running on an OS-assigned ephemeral port
    /// because the configured port could not be bound.
    let usesEphemeralFallback: Bool
    let routes: [CmxAttachRoute]
    let activeConnectionCount: Int
    let lastErrorDescription: String?

    var payload: [String: Any] {
        [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "configured_port": configuredPort,
            "uses_ephemeral_fallback": usesEphemeralFallback,
            "routes": routes.map(\.mobileHostJSONObject),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull()
        ]
    }
}

/// What ``MobileHostService/syncToSettings()`` should do to reconcile
/// the live listener with the current settings. A pure value so the
/// restart-on-port-change logic is unit-testable without a real `NWListener`.
enum MobileHostSyncDecision: Equatable {
    case noop
    case start
    case stop
    case restart
}

/// Outcome of an explicit "Apply port" request from settings. A pure value so
/// ``MobileHostService/portApplyDecision(enabled:currentBoundPort:requestedPort:isAvailable:)``
/// is unit-testable without binding a real `NWListener`.
enum MobileHostPortApplyOutcome: Equatable {
    /// The port was accepted; the listener is (or will be) bound to it.
    case applied(Int)
    /// The port is in use by another process; the running listener was left untouched.
    case portInUse
    /// Pairing is off, so the port was saved and will bind when pairing is enabled.
    case savedWhileDisabled
    /// The requested port was outside the valid `1...65535` range.
    case invalid
}

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

    private init() {}

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
        guard MobileHostEventSubscriptionTracker.hasSubscribers(topic: topic) else {
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
        MobileHostEventSubscriptionTracker.hasSubscribers(topic: topic)
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

    /// Pure reconciliation between the desired settings and the live listener
    /// state. Factored out so the restart-on-port-change decision is unit
    /// testable without binding a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether the iOS pairing host is enabled in settings.
    ///   - listenerRunning: Whether a listener is currently bound.
    ///   - desiredPort: The preferred port from settings (``configuredPort(defaults:)``).
    ///   - appliedPort: The preferred port the running listener targeted, or
    ///     `nil` when stopped.
    /// - Returns: The action ``syncToSettings()`` should take.
    nonisolated static func syncDecision(
        enabled: Bool,
        listenerRunning: Bool,
        desiredPort: Int,
        appliedPort: Int?
    ) -> MobileHostSyncDecision {
        guard enabled else { return listenerRunning ? .stop : .noop }
        guard listenerRunning else { return .start }
        if appliedPort != desiredPort { return .restart }
        return .noop
    }

    /// Pure pre-bind classification for an explicit "Apply port" request. Returns
    /// the outcome for the cases that need no bind attempt, or `nil` when a real
    /// bind must be tried (pairing on, valid port, different from the bound one).
    /// Factored out so the decision is unit-testable without a real `NWListener`.
    ///
    /// - Parameters:
    ///   - enabled: Whether iOS pairing is enabled in settings.
    ///   - currentBoundPort: The port the listener is currently bound to, or `nil`.
    ///   - requestedPort: The port the user asked to apply.
    nonisolated static func portApplyPreBindOutcome(
        enabled: Bool,
        currentBoundPort: Int?,
        requestedPort: Int
    ) -> MobileHostPortApplyOutcome? {
        guard (1...65535).contains(requestedPort) else { return .invalid }
        guard enabled else { return .savedWhileDisabled }
        if currentBoundPort == requestedPort { return .applied(requestedPort) }
        return nil
    }

    /// Whether `error` means the address/port cannot be bound (in use, not
    /// available, or permission denied) versus a transient waiting reason.
    nonisolated static func isAddressUnavailable(_ error: NWError) -> Bool {
        if case let .posix(code) = error {
            return code == .EADDRINUSE || code == .EADDRNOTAVAIL || code == .EACCES
        }
        return false
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
        if let preBind = Self.portApplyPreBindOutcome(
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
                    if Self.isAddressUnavailable(error) { finish(false) }
                default:
                    break
                }
            }
            // NWListener needs a newConnectionHandler set before `start()` or it
            // never reaches `.ready`; wiring the real accept path (with this
            // generation) also means no connection is dropped once it's adopted.
            candidate.newConnectionHandler = { connection in
                MobileHostRequestActivity.beginConnection()
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
                MobileHostRequestActivity.beginConnection()
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
        MobileHostEventSubscriptionTracker.reset()
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
        switch Self.syncDecision(
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
                MobileHostRequestActivity.endConnection()
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
            if Self.isLoopbackConnection(connection) {
                mobileHostLog.error("mobile host rejected loopback connection in release build")
                connection.cancel()
                MobileHostRequestActivity.endConnection()
                return
            }
            #endif

            let id = UUID()
            let session = MobileHostConnection(
                id: id,
                connection: connection,
                authorizeRequest: { request in
                    if !Self.requiresAuthorization(method: request.method) {
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
                }
            )
            guard MobileHostConnectionRegistry.shared.insert(
                session,
                id: id,
                limit: Self.maximumActiveConnectionCount
            ) else {
                mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
                connection.cancel()
                MobileHostRequestActivity.endConnection()
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
        let selectedRoutes = try Self.filteredRoutes(
            routes,
            routeID: routeID,
            routeKind: routeKind
        )
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

    private static func filteredRoutes(
        _ routes: [CmxAttachRoute],
        routeID: String?,
        routeKind: String?
    ) throws -> [CmxAttachRoute] {
        let normalizedRouteID = routeID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRouteKind = routeKind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hasRouteID = normalizedRouteID?.isEmpty == false
        let hasRouteKind = normalizedRouteKind?.isEmpty == false
        guard hasRouteID || hasRouteKind else {
            return routes
        }

        let filtered = routes.filter { route in
            if hasRouteID, route.id != normalizedRouteID {
                return false
            }
            if hasRouteKind, route.kind.rawValue != normalizedRouteKind {
                return false
            }
            return true
        }
        guard !filtered.isEmpty else {
            throw MobileAttachTicketStoreError.routeUnavailable
        }
        return filtered
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard listener != nil, generation == listenerGeneration else {
            connection.cancel()
            MobileHostRequestActivity.endConnection()
            return
        }
        guard activeConnections.count < Self.maximumActiveConnectionCount else {
            mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
            connection.cancel()
            MobileHostRequestActivity.endConnection()
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
            }
        )
        activeConnections[id] = session
        Task { await session.start() }
    }

    /// Whether an incoming connection's remote peer is on the loopback interface.
    ///
    /// Used to refuse local connections in release builds, where no legitimate
    /// client ever connects via `127.0.0.1`/`::1`.
    nonisolated static func isLoopbackConnection(_ connection: NWConnection) -> Bool {
        isLoopbackEndpoint(connection.endpoint) || isLoopbackEndpoint(connection.currentPath?.remoteEndpoint)
    }

    nonisolated static func isLoopbackEndpoint(_ endpoint: NWEndpoint?) -> Bool {
        guard case let .hostPort(host, _)? = endpoint else { return false }
        switch host {
        case let .ipv4(address):
            // 127.0.0.0/8
            return address.rawValue.first == 127
        case let .ipv6(address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 16 else { return false }
            // ::1
            let isV6Loopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            // IPv4-mapped loopback ::ffff:127.0.0.0/8
            let isV4MappedLoopback = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            return isV6Loopback || isV4MappedLoopback
        case let .name(name, _):
            let lowered = name.lowercased()
            return lowered == "localhost" || lowered.hasSuffix(".localhost")
        @unknown default:
            return false
        }
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
        MobileHostRequestActivity.endConnection()
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

    /// Whether `request`'s Stack token passes the DEBUG dev-token policy.
    /// Always `false` in release builds. Shared by the authorization gate and
    /// the status identity gate so a dev-token client is treated identically
    /// on both.
    private func devStackTokenAuthorized(_ request: MobileHostRPCRequest) -> Bool {
        #if DEBUG
        if let stackAccessToken = request.auth?.stackAccessToken {
            return MobileHostDevStackAuthPolicy.authorize(
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
        if let cachedVerdict = await MobileHostStackAuthVerifier.shared.cachedVerdict(auth: request.auth) {
            return cachedVerdict
        }
        guard await MobileHostStatusVerificationLimiter.shared.acquire() else {
            mobileHostLog.error("mobile host status identity withheld: verification limiter saturated")
            return false
        }
        let verified: Bool
        do {
            try await Self.verifyStackAuthOffMainActor(auth: request.auth)
            verified = true
        } catch {
            verified = false
        }
        // Non-throwing actor call: runs even if this task was cancelled
        // mid-verification, so a slot can never leak.
        await MobileHostStatusVerificationLimiter.shared.release()
        return verified
    }

    func authorizationError(for request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        guard Self.requiresAuthorization(method: request.method) else { return nil }
        if devStackTokenAuthorized(request) { return nil }
        let hasPresentedAttachToken = request.auth?.attachToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if let ticketAuthorization = ticketStore.validAuthorization(authToken: request.auth?.attachToken) {
            let matchesCurrentMacAccount = MobileAttachTicketStore.ticketMatchesCurrentMacAccount(
                ticket: ticketAuthorization.ticket,
                currentUserID: await currentAuthenticatedLocalUserID(),
                currentUserEmail: await currentAuthenticatedLocalUserEmail()
            )
            if !matchesCurrentMacAccount {
                if request.auth?.stackAccessToken == nil { return .failure(Self.accountMismatchError) }
            } else if let ticketError = Self.ticketAuthorizationError(
                authorization: ticketAuthorization,
                request: request
            ) {
                if request.auth?.stackAccessToken == nil { return .failure(ticketError) }
            } else {
                return nil
            }
        } else if hasPresentedAttachToken, request.auth?.stackAccessToken == nil {
            return .failure(Self.invalidAttachTokenError)
        }
        do {
            try await Self.verifyStackAuthOffMainActor(auth: request.auth)
            return nil
        } catch MobileHostAuthorizationError.accountMismatch {
            // The presented Stack token is valid but belongs to a different
            // account than the one signed in on this Mac. Surface a distinct code
            // so the client can drive a re-authentication flow into the right
            // account rather than showing a generic failure.
            mobileHostLog.error("mobile host authorization rejected: account mismatch method=\(request.method, privacy: .public)")
            return .failure(Self.accountMismatchError)
        } catch {
            mobileHostLog.error("mobile host authorization failed method=\(request.method, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(MobileHostRPCError(
                code: "unauthorized",
                message: "Mobile sync authorization failed."
            ))
        }
    }

    private nonisolated static func verifyStackAuthOffMainActor(auth: MobileHostRPCAuth?) async throws {
        try await Task.detached(priority: .utility) {
            try await MobileHostStackAuthVerifier.shared.verify(auth: auth)
        }.value
    }

    func recordCreatedResourcesIfNeeded(
        request: MobileHostRPCRequest,
        result: MobileHostRPCResult
    ) {
        guard let attachToken = request.auth?.attachToken, let ticketAuthorization = ticketStore.validAuthorization(authToken: attachToken), Self.ticketAuthorizationError(authorization: ticketAuthorization, request: request) == nil else { return }
        guard MobileAttachTicketStore.ticketMatchesCurrentMacAccount(
            ticket: ticketAuthorization.ticket,
            currentUserID: await currentAuthenticatedLocalUserID(),
            currentUserEmail: await currentAuthenticatedLocalUserEmail()
        ) else { return }
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

    private static func ticketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(
            authorization: MobileAttachTicketAuthorization(
                ticket: ticket,
                createdWorkspaceIDs: [],
                createdTerminalIDs: []
            ),
            request: request
        )
    }

    private static func ticketAuthorizationError(
        authorization: MobileAttachTicketAuthorization,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        let workspaceSelection = stringParamSelection(
            request.params,
            keys: ["workspace_id"]
        )
        let terminalSelection = stringParamSelection(
            request.params,
            keys: ["surface_id", "terminal_id", "tab_id"]
        )
        if workspaceSelection.hasConflict || terminalSelection.hasConflict {
            return scopedTicketError
        }
        if containsIgnoredAliasParameters(request.params) {
            return scopedTicketError
        }

        switch request.method {
        case "mobile.workspace.list", "workspace.list":
            return authorization.ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && workspaceSelection.value == nil ? scopedTicketError : ticketTerminalAuthorizationError(authorization: authorization, workspaceSelection: workspaceSelection.value, terminalSelection: terminalSelection.value)
        case "workspace.create":
            return ticketWorkspaceAuthorizationError(authorization: authorization, workspaceSelection: nil)
        case "workspace.group.collapse", "workspace.group.expand":
            return ticketWorkspaceAuthorizationError(authorization: authorization, workspaceSelection: nil)
        case "workspace.action", "workspace.close":
            return ticketWorkspaceAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value
            )
        case "mobile.terminal.create", "terminal.create":
            return terminalSelection.value != nil || authorization.ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? scopedTicketError : ticketWorkspaceAuthorizationError(authorization: authorization, workspaceSelection: workspaceSelection.value)
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.paste", "terminal.paste",
             "mobile.terminal.paste_image", "terminal.paste_image",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.scroll", "terminal.scroll",
             "mobile.terminal.mouse", "terminal.mouse":
            return ticketTerminalAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return ticketWorkspaceAuthorizationError(authorization: authorization, workspaceSelection: nil)
        case "mobile.host.status":
            return nil
        default:
            return scopedTicketError
        }
    }

    private static func ticketWorkspaceAuthorizationError(
        authorization: MobileAttachTicketAuthorization,
        workspaceSelection: String?
    ) -> MobileHostRPCError? {
        if let workspaceSelection,
           authorization.createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }

        let ticketWorkspaceID = authorization.ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // Allow any workspace under it.
        if ticketWorkspaceID.isEmpty {
            return nil
        }
        guard workspaceSelection == ticketWorkspaceID else {
            return scopedTicketError
        }
        return nil
    }

    private static func ticketTerminalAuthorizationError(
        authorization: MobileAttachTicketAuthorization,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> MobileHostRPCError? {
        if let terminalSelection,
           authorization.createdTerminalIDs.contains(terminalSelection) {
            return nil
        }
        if let workspaceSelection,
           authorization.createdWorkspaceIDs.contains(workspaceSelection) {
            return nil
        }

        let ticket = authorization.ticket
        let ticketWorkspaceID = ticket.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        // Empty workspaceID means the ticket is Mac-wide (general pairing).
        // Allow any workspace/terminal under it.
        if ticketWorkspaceID.isEmpty {
            return nil
        }
        if let workspaceSelection, workspaceSelection != ticketWorkspaceID {
            return scopedTicketError
        }

        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            guard terminalSelection == terminalID else {
                return scopedTicketError
            }
            return nil
        }

        guard workspaceSelection == ticketWorkspaceID else {
            return scopedTicketError
        }
        return nil
    }

    static func debugTicketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest,
        createdWorkspaceIDs: Set<String> = [],
        createdTerminalIDs: Set<String> = []
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(
            authorization: MobileAttachTicketAuthorization(
                ticket: ticket,
                createdWorkspaceIDs: createdWorkspaceIDs,
                createdTerminalIDs: createdTerminalIDs
            ),
            request: request
        )
    }

    private static var scopedTicketError: MobileHostRPCError {
        MobileHostRPCError(
            code: "forbidden",
            message: "Attach ticket is not valid for this workspace or terminal."
        )
    }

    private static var invalidAttachTokenError: MobileHostRPCError {
        MobileHostRPCError(code: "invalid_attach_token", message: "Attach token is no longer valid.")
    }

    private static var accountMismatchError: MobileHostRPCError {
        MobileHostRPCError(
            code: "account_mismatch",
            message: "Sign in with the account that owns this Mac to continue."
        )
    }
    private static func containsIgnoredAliasParameters(_ params: [String: Any]) -> Bool {
        params["workspaceID"] != nil || params["terminalID"] != nil
    }

    private static func stringParamSelection(
        _ params: [String: Any],
        keys: [String]
    ) -> StringParamSelection {
        var selected: String?
        for key in keys {
            if let value = params[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    if let selected, selected != trimmed {
                        return StringParamSelection(value: selected, hasConflict: true)
                    }
                    selected = selected ?? trimmed
                }
            }
        }
        return StringParamSelection(value: selected, hasConflict: false)
    }

    private struct StringParamSelection {
        let value: String?
        let hasConflict: Bool
    }

    nonisolated private static func requiresAuthorization(method: String) -> Bool {
        switch method {
        // Only the unauthenticated host probe is exempt. `mobile.attach_ticket.create`
        // mints a bearer credential, so it MUST be authorized: a network caller has no
        // attach token yet, so it is routed through the same-account Stack Auth token
        // (the iOS client always sends it for this method). Leaving it exempt would let
        // any process that can speak the wire protocol self-issue a working ticket and
        // take over the terminal. The on-Mac QR pairing mints tickets through the local
        // automation socket (`TerminalController`), not this network path, so it is
        // unaffected.
        case "mobile.host.status":
            return false
        default:
            return true
        }
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
            if Self.isAddressUnavailable(error) {
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
        MobileHostRequestActivity.resetForTesting()
        MobileHostEventSubscriptionTracker.resetForTesting()
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
        debugAcceptedStackAuthToken = MobileHostDevStackAuthPolicy.normalizedToken(token)
    }

    func debugAcceptedStackAuthTokenForTesting() -> String? {
        debugAcceptedStackAuthToken
    }

    nonisolated static func debugHasEventSubscribersForTesting(topic: String) -> Bool {
        MobileHostEventSubscriptionTracker.hasSubscribers(topic: topic)
    }

    nonisolated static func debugResetEventSubscriptionsForTesting() {
        MobileHostEventSubscriptionTracker.resetForTesting()
    }
}
#endif

private enum MobileHostAuthorizationError: Error {
    case missingStackTokens
    case invalidStackUser
    case missingLocalUser
    case accountMismatch
    case verificationTimedOut
}

enum MobileHostAuthorizationPolicy {
    static func authorizeStackUserID(localUserID: String?, remoteUserID: String?) throws {
        guard let localUserID = normalizedUserID(localUserID) else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard normalizedUserID(remoteUserID) == localUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
    }

    private static func normalizedUserID(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

#if DEBUG
enum MobileHostDevStackAuthPolicy {
    static func normalizedToken(_ token: String?) -> String? {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func authorize(providedToken: String, acceptedToken: String?) -> Bool {
        guard let acceptedToken = normalizedToken(acceptedToken) else {
            return false
        }
        return normalizedToken(providedToken) == acceptedToken
    }
}
#endif

private actor MobileHostStackAuthVerifier {
    static let shared = MobileHostStackAuthVerifier()
    private static let verificationTimeoutNanoseconds: UInt64 = 10 * 1_000_000_000

    private struct CacheEntry {
        let userID: String?
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var refreshingKeys: Set<String> = []
    private static let cacheTTLSeconds: TimeInterval = 60
    private static let refreshAheadWindowSeconds: TimeInterval = 15

    /// The verification verdict for `auth`'s token using only the cache, or
    /// `nil` when no fresh cached binding exists (deciding would need a Stack
    /// network lookup). Lets the unauthenticated status path answer
    /// already-verified callers without spending a capped network slot.
    func cachedVerdict(auth: MobileHostRPCAuth?) async -> Bool? {
        guard let accessToken = auth?.stackAccessToken else {
            return false
        }
        guard let cached = cache[Self.cacheKey(for: accessToken)],
              cached.expiresAt > Date() else {
            return nil
        }
        let localUserID = await currentAuthenticatedLocalUserID()
        return (try? MobileHostAuthorizationPolicy.authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: cached.userID
        )) != nil
    }

    func verify(auth: MobileHostRPCAuth?) async throws {
        guard let accessToken = auth?.stackAccessToken else {
            throw MobileHostAuthorizationError.missingStackTokens
        }

        let cacheKey = Self.cacheKey(for: accessToken)
        let now = Date()
        let remoteUserID: String?
        cache = cache.filter { $0.value.expiresAt > now }
        if let cached = cache[cacheKey], cached.expiresAt > now {
            remoteUserID = cached.userID
            // Refresh-ahead: when the cached binding is near expiry, re-verify in
            // the background so a Stack-authenticated request never blocks a
            // keystroke on the network round-trip.
            if cached.expiresAt.timeIntervalSince(now) < Self.refreshAheadWindowSeconds {
                scheduleRefreshAhead(cacheKey: cacheKey, accessToken: accessToken)
            }
        } else {
            remoteUserID = try await fetchAndCacheRemoteUserID(cacheKey: cacheKey, accessToken: accessToken)
        }

        let localUserID = await currentAuthenticatedLocalUserID()
        try MobileHostAuthorizationPolicy.authorizeStackUserID(
            localUserID: localUserID,
            remoteUserID: remoteUserID
        )
    }

    private func fetchAndCacheRemoteUserID(cacheKey: String, accessToken: String) async throws -> String? {
        let stack = Self.makeStackClient(accessToken: accessToken)
        guard let user = try await Self.withVerificationTimeout({
            try await stack.getUser(or: .throw)
        }) else {
            throw MobileHostAuthorizationError.invalidStackUser
        }
        let remoteUserID = await user.id
        cache[cacheKey] = CacheEntry(
            userID: remoteUserID,
            expiresAt: Date().addingTimeInterval(Self.cacheTTLSeconds)
        )
        return remoteUserID
    }

    private func scheduleRefreshAhead(cacheKey: String, accessToken: String) {
        guard !refreshingKeys.contains(cacheKey) else { return }
        refreshingKeys.insert(cacheKey)
        Task { await self.refreshAhead(cacheKey: cacheKey, accessToken: accessToken) }
    }

    private func refreshAhead(cacheKey: String, accessToken: String) async {
        defer { refreshingKeys.remove(cacheKey) }
        // Best-effort: on failure leave the existing entry to expire naturally.
        _ = try? await fetchAndCacheRemoteUserID(cacheKey: cacheKey, accessToken: accessToken)
    }

    private static func makeStackClient(accessToken: String) -> StackClientApp {
        StackClientApp(
            projectId: AuthEnvironment.stackProjectID,
            publishableClientKey: AuthEnvironment.stackPublishableClientKey,
            baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
            tokenStore: .custom(MobileHostAccessTokenStore(accessToken: accessToken)),
            noAutomaticPrefetch: true
        )
    }

    private static func cacheKey(for accessToken: String) -> String {
        // Pure-Swift byte-to-hex (no String(format:)) — this runs for every
        // authorized mobile RPC (incl. per-keystroke terminal.input) before the
        // verifier cache hit, so it must stay allocation-cheap. String(format:)
        // here would reintroduce the PR #5347 hot-path memory-growth crash class.
        let digest = Array(SHA256.hash(data: Data(accessToken.utf8)))
        let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
        var hex = [UInt8]()
        hex.reserveCapacity(digest.count * 2)
        for byte in digest {
            hex.append(hexDigits[Int(byte >> 4)])
            hex.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: hex, as: UTF8.self)
    }

    private static func withVerificationTimeout<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: verificationTimeoutNanoseconds)
                throw MobileHostAuthorizationError.verificationTimedOut
            }

            guard let value = try await group.next() else {
                throw MobileHostAuthorizationError.verificationTimedOut
            }
            group.cancelAll()
            return value
        }
    }

    private func currentAuthenticatedLocalUserID() async -> String? {
        await MobileHostService.shared.currentAuthenticatedLocalUserID()
    }
}

private actor MobileHostAccessTokenStore: TokenStoreProtocol {
    private var accessToken: String?

    init(accessToken: String) {
        self.accessToken = accessToken
    }

    func getStoredAccessToken() async -> String? {
        accessToken
    }

    func getStoredRefreshToken() async -> String? {
        nil
    }

    func setTokens(accessToken: String?, refreshToken: String?) async {
        if let accessToken {
            self.accessToken = accessToken
        }
    }

    func clearTokens() async {
        accessToken = nil
    }

    func compareAndSet(compareRefreshToken: String, newRefreshToken: String?, newAccessToken: String?) async {
        if let newAccessToken {
            accessToken = newAccessToken
        }
    }
}

actor MobileHostConnection {
    private static let maximumReceiveBufferByteCount = MobileSyncFrameCodec.defaultMaximumFrameByteCount + MobileSyncFrameCodec.headerByteCount
    private static let defaultFirstFrameTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000
    private static let defaultIdleTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000

    private let id: UUID
    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let firstFrameTimeoutNanoseconds: UInt64
    private let idleTimeoutNanoseconds: UInt64
    private let authorizeRequest: @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult?
    private let onAuthorizedRequest: @Sendable (MobileHostRPCRequest) async -> Void
    private let handleRequest: @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult
    private let onClose: @Sendable (UUID) async -> Void
    private var receiveBuffer = Data()
    private var firstFrameTimeoutTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var didDecodeFirstFrame = false
    private var isClosed = false
    /// stream_id → set of topics this connection is subscribed to.
    /// Populated by `mobile.events.subscribe`; cleared on close.
    private var subscriptions: [String: Set<String>] = [:]

    init(
        id: UUID,
        connection: NWConnection,
        firstFrameTimeoutNanoseconds: UInt64 = MobileHostConnection.defaultFirstFrameTimeoutNanoseconds,
        idleTimeoutNanoseconds: UInt64 = MobileHostConnection.defaultIdleTimeoutNanoseconds,
        authorizeRequest: @escaping @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult?,
        onAuthorizedRequest: @escaping @Sendable (MobileHostRPCRequest) async -> Void,
        handleRequest: @escaping @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        self.id = id
        self.connection = connection
        self.callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-connection.\(id.uuidString)")
        self.firstFrameTimeoutNanoseconds = firstFrameTimeoutNanoseconds
        self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
        self.authorizeRequest = authorizeRequest
        self.onAuthorizedRequest = onAuthorizedRequest
        self.handleRequest = handleRequest
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self, id] state in
            guard let self else { return }
            Task { await self.handleState(state, connectionID: id) }
        }
        connection.start(queue: callbackQueue)
        startFirstFrameTimeout()
        receiveNext()
    }

    func close(reason: String) {
        guard !isClosed else {
            return
        }
        isClosed = true
        firstFrameTimeoutTask?.cancel()
        firstFrameTimeoutTask = nil
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
        let tasks = responseTasks.values
        responseTasks.removeAll()
        for task in tasks {
            task.cancel()
        }
        let previousSubscriptions = Array(subscriptions.values)
        subscriptions.removeAll()
        for topics in previousSubscriptions where !topics.isEmpty {
            MobileHostEventSubscriptionTracker.replace(
                previousTopics: topics,
                nextTopics: nil
            )
        }
        mobileHostLog.info("mobile host connection closed \(self.id.uuidString, privacy: .public): \(reason, privacy: .public)")
        connection.stateUpdateHandler = nil
        connection.cancel()
        Task { await onClose(id) }
    }

    private func receiveNext() {
        guard !isClosed else {
            return
        }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            let errorDescription = error.map { String(describing: $0) }
            Task {
                await self.handleReceive(
                    data: data,
                    isComplete: isComplete,
                    errorDescription: errorDescription
                )
            }
        }
    }

    private func handleReceive(
        data: Data?,
        isComplete: Bool,
        errorDescription: String?
    ) async {
        if let errorDescription {
            close(reason: errorDescription)
            return
        }

        if let data, !data.isEmpty {
            idleTimeoutTask?.cancel()
            idleTimeoutTask = nil
            guard receiveBuffer.count + data.count <= Self.maximumReceiveBufferByteCount else {
                _ = await sendResponse(
                    MobileHostRPCEnvelope.error(
                        id: nil,
                        code: "frame_decode_error",
                        message: "Invalid frame"
                    )
                )
                close(reason: "receive buffer exceeded frame limit")
                return
            }
            receiveBuffer.append(data)
            do {
                let frames = try MobileSyncFrameCodec.decodeFrames(from: &receiveBuffer)
                if !frames.isEmpty {
                    didDecodeFirstFrame = true
                    firstFrameTimeoutTask?.cancel()
                    firstFrameTimeoutTask = nil
                }
                for frame in frames {
                    guard !isClosed else {
                        return
                    }
                    startResponseTask(for: frame)
                }
                guard !isClosed else {
                    return
                }
                startIdleTimeout()
            } catch {
                _ = await sendResponse(
                    MobileHostRPCEnvelope.error(
                        id: nil,
                        code: "frame_decode_error",
                        message: "Invalid frame"
                    )
                )
                close(reason: "frame decode error")
                return
            }
        }

        if isComplete {
            close(reason: "remote closed")
        } else {
            receiveNext()
        }
    }

    private func startResponseTask(for frame: Data) {
        guard !isClosed else {
            return
        }
        let taskID = UUID()
        let task = Task { [weak self] in
            await self?.respond(to: frame)
            await self?.finishResponseTask(taskID)
        }
        responseTasks[taskID] = task
    }

    private func finishResponseTask(_ taskID: UUID) {
        responseTasks[taskID] = nil
        if responseTasks.isEmpty {
            startIdleTimeout()
        }
    }

    private func startFirstFrameTimeout() {
        guard firstFrameTimeoutNanoseconds > 0 else {
            return
        }
        firstFrameTimeoutTask?.cancel()
        let timeoutNanoseconds = firstFrameTimeoutNanoseconds
        firstFrameTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.closeIfWaitingForFirstFrame()
            } catch {}
        }
    }

    private func closeIfWaitingForFirstFrame() {
        guard !didDecodeFirstFrame else {
            return
        }
        close(reason: "first frame timed out")
    }

    private func startIdleTimeout() {
        guard idleTimeoutNanoseconds > 0,
              didDecodeFirstFrame,
              !isClosed,
              subscriptions.isEmpty,
              responseTasks.isEmpty else {
            return
        }
        idleTimeoutTask?.cancel()
        let timeoutNanoseconds = idleTimeoutNanoseconds
        idleTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                await self?.closeIfIdleAfterFrame()
            } catch {}
        }
    }

    private func closeIfIdleAfterFrame() {
        guard didDecodeFirstFrame, subscriptions.isEmpty, responseTasks.isEmpty else {
            return
        }
        close(reason: "idle after frame timed out")
    }

    private func respond(to frame: Data) async {
        guard !isClosed, !Task.isCancelled else {
            return
        }
        switch MobileHostRPCEnvelope.decodeRequest(frame) {
        case let .success(request):
            let tracksInteractiveActivity = Self.isInteractiveMobileRequest(request.method)
            if tracksInteractiveActivity {
                MobileHostRequestActivity.beginRequest()
            }
            defer {
                if tracksInteractiveActivity {
                    MobileHostRequestActivity.endRequest()
                }
            }
            if let error = await authorizeRequest(request) {
                guard !isClosed, !Task.isCancelled else {
                    return
                }
                _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: error))
                return
            }
            guard !isClosed, !Task.isCancelled else {
                return
            }
            if let intercepted = handleSubscriptionRPC(request) {
                _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: intercepted))
                return
            }
            await onAuthorizedRequest(request)
            guard !isClosed, !Task.isCancelled else {
                return
            }
            let result = await handleRequest(request)
            guard !isClosed, !Task.isCancelled else {
                return
            }
            _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: result))
        case let .failure(error):
            guard !isClosed, !Task.isCancelled else {
                return
            }
            _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: nil, result: .failure(error)))
            close(reason: "invalid rpc envelope")
        }
    }

    private func handleSubscriptionRPC(_ request: MobileHostRPCRequest) -> MobileHostRPCResult? {
        switch request.method {
        case "mobile.events.subscribe":
            let streamID = (request.params["stream_id"] as? String) ?? UUID().uuidString
            let topicsArray = (request.params["topics"] as? [String]) ?? []
            let topics = Set(topicsArray.filter { !$0.isEmpty })
            guard !topics.isEmpty else {
                return .failure(MobileHostRPCError(code: "invalid_params", message: "topics is required"))
            }
            // Report whether this stream id was already registered BEFORE the
            // idempotent replace. The phone's render-grid liveness probe
            // re-asserts its subscription on prolonged silence; `false` tells
            // it the registration had been lost (events emitted in the gap
            // were never delivered), so it requests a catch-up replay instead
            // of trusting delta continuity.
            let alreadySubscribed = subscriptions[streamID] != nil
            subscribe(streamID: streamID, topics: topics)
            #if DEBUG
            cmuxDebugLog("mobile.subscribe streamID=\(streamID) topics=\(topics.sorted()) existing=\(alreadySubscribed) connID=\(self.id.uuidString)")
            #endif
            return .ok([
                "stream_id": streamID,
                "topics": Array(topics).sorted(),
                "already_subscribed": alreadySubscribed,
            ])
        case "mobile.events.unsubscribe":
            let streamID = request.params["stream_id"] as? String ?? ""
            let removed = unsubscribe(streamID: streamID)
            return .ok([
                "stream_id": streamID,
                "removed": removed,
            ])
        default:
            return nil
        }
    }

    private static func isInteractiveMobileRequest(_ method: String) -> Bool {
        switch method {
        case "mobile.host.status", "mobile.terminal.replay", "terminal.replay",
             // Subscription management is plumbing, not user interaction: the
             // phone's render-grid liveness watchdog re-asserts its
             // subscription on every silence window (~9s when idle), and
             // counting that as interactive activity starves host work gated
             // on mobile quiet (e.g. TabManager background git/PR refresh).
             "mobile.events.subscribe", "mobile.events.unsubscribe":
            return false
        default:
            return true
        }
    }

    /// Add a subscription for this connection. Idempotent per stream_id.
    func subscribe(streamID: String, topics: Set<String>) {
        let previousTopics = subscriptions[streamID]
        subscriptions[streamID] = topics
        MobileHostEventSubscriptionTracker.replace(
            previousTopics: previousTopics,
            nextTopics: topics
        )
        idleTimeoutTask?.cancel()
        idleTimeoutTask = nil
    }

    /// Remove a subscription by id. Returns true if it existed.
    @discardableResult
    func unsubscribe(streamID: String) -> Bool {
        let previousTopics = subscriptions.removeValue(forKey: streamID)
        let removed = previousTopics != nil
        if let previousTopics {
            MobileHostEventSubscriptionTracker.replace(previousTopics: previousTopics, nextTopics: nil)
        }
        if subscriptions.isEmpty {
            startIdleTimeout()
        }
        return removed
    }

    /// Check whether this connection has any subscriber registered for `topic`.
    func isSubscribed(to topic: String) -> Bool {
        for (_, topics) in subscriptions where topics.contains(topic) {
            return true
        }
        return false
    }

    /// Send a server-pushed event envelope to this connection. Returns true
    /// if the event was actually written to the wire. No-ops if the
    /// connection is closed or not subscribed to the topic.
    @discardableResult
    func sendEvent(topic: String, payload: [String: Any]) async -> Bool {
        guard !isClosed else {
            #if DEBUG
            cmuxDebugLog("mobile.send skip: closed topic=\(topic) connID=\(self.id.uuidString)")
            #endif
            return false
        }
        guard isSubscribed(to: topic) else {
            #if DEBUG
            cmuxDebugLog("mobile.send skip: not subscribed topic=\(topic) connID=\(self.id.uuidString) subs=\(subscriptions.count)")
            #endif
            return false
        }
        let envelope: [String: Any] = [
            "kind": "event",
            "topic": topic,
            "payload": payload,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return false }
        return await sendResponse(data)
    }

    private func sendResponse(_ response: Data) async -> Bool {
        guard !isClosed else {
            return false
        }
        let frame: Data
        do {
            frame = try MobileSyncFrameCodec.encodeFrame(response)
        } catch {
            close(reason: "response frame encode failed")
            return false
        }

        return await withCheckedContinuation { continuation in
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        continuation.resume(returning: false)
                        return
                    }
                    if let error {
                        Task { await self.close(reason: String(describing: error)) }
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(returning: true)
                    }
                }
            )
        }
    }

    private func handleState(_ state: NWConnection.State, connectionID: UUID) {
        switch state {
        case .failed(let error):
            close(reason: String(describing: error))
        case .cancelled:
            close(reason: "cancelled")
        case .ready:
            mobileHostLog.debug("mobile host connection ready \(connectionID.uuidString, privacy: .public)")
        case .setup, .waiting, .preparing:
            break
        @unknown default:
            break
        }
    }
}

#if DEBUG
extension MobileHostConnection {
    func debugStartFirstFrameTimeoutForTesting() {
        startFirstFrameTimeout()
    }

    func debugStartIdleTimeoutAfterFrameForTesting() {
        didDecodeFirstFrame = true
        startIdleTimeout()
    }

    func debugHandleReceiveDataForTesting(_ data: Data) async {
        await handleReceive(
            data: data,
            isComplete: false,
            errorDescription: nil
        )
    }
}
#endif
