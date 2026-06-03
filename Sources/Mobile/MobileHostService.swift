import CMUXMobileCore
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

extension Notification.Name {
    static let mobileHostEventSubscriptionsDidChange = Notification.Name(
        "cmux.mobileHostEventSubscriptionsDidChange"
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
        defer { lock.unlock() }
        guard connections.count < limit else {
            return false
        }
        connections[id] = connection
        return true
    }

    func remove(id: UUID) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }

    func removeAll() -> [MobileHostConnection] {
        lock.lock()
        let values = Array(connections.values)
        connections.removeAll()
        lock.unlock()
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
    }

    static func result() -> MobileHostRPCResult {
        lock.lock()
        let cachedRoutes = routes
        lock.unlock()
        return .ok([
            "routes": cachedRoutes.map(\.mobileHostJSONObject),
            "terminal_fidelity": "render_grid",
            "capabilities": [
                "events.v1",
                "terminal.bytes.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "terminal.viewport.v1",
            ],
        ])
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
    let routes: [CmxAttachRoute]
    let activeConnectionCount: Int
    let lastErrorDescription: String?

    var payload: [String: Any] {
        [
            "is_running": isRunning,
            "port": port ?? NSNull(),
            "routes": routes.map(\.mobileHostJSONObject),
            "active_connection_count": activeConnectionCount,
            "last_error": lastErrorDescription ?? NSNull()
        ]
    }
}

@MainActor
final class MobileHostService {
    static let shared = MobileHostService()
    static let preferredPort = CmxMobileDefaults.defaultHostPort
    nonisolated private static let maximumActiveConnectionCount = 10

    private let callbackQueue = DispatchQueue(label: "dev.cmux.mobile.host-listener")
    private let routeResolver = MobileRouteResolver()
    private let ticketStore = MobileAttachTicketStore()
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var listenerUsesEphemeralFallback = false
    private var listenerPort: Int?
    private var activeConnections: [UUID: MobileHostConnection] = [:]
    private var clientIDsByConnectionID: [UUID: Set<String>] = [:]
    private var lastErrorDescription: String?
    #if DEBUG
    private var debugAcceptedStackAuthToken: String?
    #endif

    private init() {}

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

    /// User-default key overriding ``isListeningEnabled``. When set, its boolean
    /// value wins over the build-configuration default.
    static let listeningEnabledDefaultsKey = "cmuxMobilePairingHostEnabled"

    /// Whether the mobile pairing host should bind a network listener at all.
    ///
    /// Defaults **on** for dev and nightly builds so the iOS app pairs in dogfood
    /// and in the nightly channel without setup, and **off** for stable: a stable
    /// Mac that never pairs a phone must not expose a network listener for a
    /// feature it can't use yet. The `cmuxMobilePairingHostEnabled` user default
    /// overrides the default in any build (including stable), so the feature can
    /// be flipped on without a new build once the iOS app ships broadly.
    static var isListeningEnabled: Bool {
        if let override = UserDefaults.standard.object(forKey: listeningEnabledDefaultsKey) as? Bool {
            return override
        }
        return BuildFlavor.current != .stable
    }

    func start() {
        guard Self.isListeningEnabled else {
            mobileHostLog.info("mobile host listener disabled; not binding")
            return
        }
        guard listener == nil else {
            return
        }

        startListener(usePreferredPort: true)
    }

    private func startListener(usePreferredPort: Bool) {
        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            let nextListener = try makeListener(parameters: parameters, usePreferredPort: usePreferredPort)
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
        } catch {
            if usePreferredPort {
                mobileHostLog.info("mobile host preferred port unavailable before listener start, falling back to an ephemeral port")
                startListener(usePreferredPort: false)
                return
            }
            lastErrorDescription = String(describing: error)
            mobileHostLog.error("mobile host listener failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    private func makeListener(parameters: NWParameters, usePreferredPort: Bool) throws -> NWListener {
        if usePreferredPort, let preferredPort = NWEndpoint.Port(rawValue: UInt16(Self.preferredPort)) {
            return try NWListener(using: parameters, on: preferredPort)
        }
        return try NWListener(using: parameters, on: .any)
    }

    func stop() {
        listenerGeneration = UUID()
        listenerUsesEphemeralFallback = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerPort = nil
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
    }

    func statusSnapshot() -> MobileHostServiceStatus {
        let routes = listenerPort.map { routeResolver.routes(port: $0).routes } ?? []
        return MobileHostServiceStatus(
            isRunning: listener != nil && listenerPort != nil,
            port: listenerPort,
            routes: routes,
            activeConnectionCount: MobileHostConnectionRegistry.shared.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func publicStatusSnapshot() async -> MobileHostServiceStatus {
        let routes: [CmxAttachRoute]
        if let listenerPort {
            routes = routeResolver.routes(port: listenerPort).routes
        } else {
            routes = []
        }
        return MobileHostServiceStatus(
            isRunning: listener != nil && listenerPort != nil,
            port: listenerPort,
            routes: routes,
            activeConnectionCount: MobileHostConnectionRegistry.shared.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func publicHostStatusResult() async -> MobileHostRPCResult {
        let status = await publicStatusSnapshot()
        return .ok([
            "routes": status.routes.map(\.mobileHostJSONObject),
            "terminal_fidelity": "render_grid",
            "capabilities": [
                "events.v1",
                "terminal.bytes.v1",
                "terminal.render_grid.v1",
                "terminal.replay.v1",
                "terminal.viewport.v1",
            ],
        ])
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
                        return MobileHostPublicStatusCache.result()
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
            ttl: ttl
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
                    return await MobileHostService.shared.publicHostStatusResult()
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

    func debugAuthorizationError(for request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        await authorizationError(for: request)
    }

    private func authorizationError(for request: MobileHostRPCRequest) async -> MobileHostRPCResult? {
        guard Self.requiresAuthorization(method: request.method) else {
            return nil
        }
        // Stack auth is the SOLE authorization gate for the mobile data plane.
        // The attach ticket is route-discovery and workspace-selection only; it
        // never authorizes on its own. Every operation must present the Mac
        // owner's same-account Stack access token. Consequences: a leaked or
        // photographed QR is useless without the owner's signed-in account, and
        // pairing is bound to "who is signed in on this Mac" rather than a stored
        // ticket, so it survives Mac restarts and ticket expiry.
        #if DEBUG
        if let stackAccessToken = request.auth?.stackAccessToken,
           MobileHostDevStackAuthPolicy.authorize(
                providedToken: stackAccessToken,
                acceptedToken: debugAcceptedStackAuthToken
           ) {
            return nil
        }
        #endif
        do {
            try await Self.verifyStackAuthOffMainActor(auth: request.auth)
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

    private nonisolated static func verifyStackAuthOffMainActor(auth: MobileHostRPCAuth?) async throws {
        try await Task.detached(priority: .utility) {
            try await MobileHostStackAuthVerifier.shared.verify(auth: auth)
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
            return nil
        case "workspace.create":
            return nil
        case "mobile.terminal.create", "terminal.create":
            return nil
        case "mobile.terminal.input", "terminal.input",
             "mobile.terminal.replay", "terminal.replay",
             "mobile.terminal.viewport", "terminal.viewport",
             "mobile.terminal.scroll", "terminal.scroll":
            return ticketTerminalAuthorizationError(
                authorization: authorization,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.events.subscribe", "mobile.events.unsubscribe":
            return nil
        case "mobile.host.status":
            return nil
        default:
            return scopedTicketError
        }
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
        case let .failed(error):
            lastErrorDescription = String(describing: error)
            MobileHostPublicStatusCache.update(routes: [])
            mobileHostLog.error("mobile host listener failed: \(String(describing: error), privacy: .public)")
            let shouldRetryWithEphemeralPort = !listenerUsesEphemeralFallback
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listenerGeneration = UUID()
            listener = nil
            listenerUsesEphemeralFallback = false
            listenerPort = nil
            if shouldRetryWithEphemeralPort {
                mobileHostLog.info("mobile host preferred port failed after start, falling back to an ephemeral port")
                startListener(usePreferredPort: false)
            }
        case .cancelled:
            listenerGeneration = UUID()
            listener = nil
            listenerUsesEphemeralFallback = false
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
        case .setup, .waiting:
            listenerPort = nil
            MobileHostPublicStatusCache.update(routes: [])
        @unknown default:
            break
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
    static func authorizeStackUser(localUserID: String?, remoteUserID: String) throws {
        guard let localUserID, !localUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MobileHostAuthorizationError.missingLocalUser
        }
        guard localUserID == remoteUserID else {
            throw MobileHostAuthorizationError.accountMismatch
        }
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
        let userID: String
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]
    private var refreshingKeys: Set<String> = []
    private static let cacheTTLSeconds: TimeInterval = 60
    private static let refreshAheadWindowSeconds: TimeInterval = 15

    func verify(auth: MobileHostRPCAuth?) async throws {
        guard let accessToken = auth?.stackAccessToken else {
            throw MobileHostAuthorizationError.missingStackTokens
        }

        let cacheKey = Self.cacheKey(for: accessToken)
        let now = Date()
        let remoteUserID: String
        cache = cache.filter { $0.value.expiresAt > now }
        if let cached = cache[cacheKey], cached.expiresAt > now {
            remoteUserID = cached.userID
            // Refresh-ahead: when the cached binding is near expiry, re-verify in
            // the background so an actively-typing client never blocks a keystroke
            // on the network round-trip. Every mobile request now requires Stack
            // auth, so the verification must stay off the critical path.
            if cached.expiresAt.timeIntervalSince(now) < Self.refreshAheadWindowSeconds {
                scheduleRefreshAhead(cacheKey: cacheKey, accessToken: accessToken)
            }
        } else {
            remoteUserID = try await fetchAndCacheRemoteUserID(cacheKey: cacheKey, accessToken: accessToken)
        }

        let localUserID = await currentAuthenticatedLocalUserID()
        try MobileHostAuthorizationPolicy.authorizeStackUser(
            localUserID: localUserID,
            remoteUserID: remoteUserID
        )
    }

    private func fetchAndCacheRemoteUserID(cacheKey: String, accessToken: String) async throws -> String {
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
        let digest = SHA256.hash(data: Data(accessToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
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
        await AuthManager.shared.awaitBootstrapped()
        return await MainActor.run {
            guard AuthManager.shared.isAuthenticated else {
                return nil
            }
            return AuthManager.shared.currentUser?.id
        }
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
            subscribe(streamID: streamID, topics: topics)
            #if DEBUG
            cmuxDebugLog("mobile.subscribe streamID=\(streamID) topics=\(topics.sorted()) connID=\(self.id.uuidString)")
            #endif
            return .ok([
                "stream_id": streamID,
                "topics": Array(topics).sorted(),
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
        case "mobile.host.status", "mobile.terminal.replay", "terminal.replay":
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
