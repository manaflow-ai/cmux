import CMUXMobileCore
import CryptoKit
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

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
            "snapshot_fidelity": "plain_text"
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
        return activeRequestCount > 0 || activeConnectionCount > 0
    }

    static func hasRecentActivity(within interval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0, activeConnectionCount == 0 else { return true }
        guard lastActivityUptime > 0 else { return false }
        return ProcessInfo.processInfo.systemUptime - lastActivityUptime < interval
    }

    static func quietDelay(for interval: TimeInterval) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard activeRequestCount == 0, activeConnectionCount == 0 else { return interval }
        guard lastActivityUptime > 0 else { return 0 }
        let elapsed = ProcessInfo.processInfo.systemUptime - lastActivityUptime
        return max(0, interval - elapsed)
    }

    static func beginConnection() {
        lock.lock()
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
        activeConnectionCount += 1
        lock.unlock()
    }

    static func endConnection() {
        lock.lock()
        activeConnectionCount = max(0, activeConnectionCount - 1)
        lastActivityUptime = ProcessInfo.processInfo.systemUptime
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

    func start() {
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
            "snapshot_fidelity": "plain_text"
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
                    return await TerminalController.shared.mobileHostHandleRPC(request)
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
                return await TerminalController.shared.mobileHostHandleRPC(request)
            },
            onClose: { id in
                await MobileHostService.shared.removeConnection(id: id)
            }
        )
        activeConnections[id] = session
        Task { await session.start() }
    }

    private func removeConnection(id: UUID) {
        MobileHostConnectionRegistry.shared.remove(id: id)
        activeConnections.removeValue(forKey: id)
        clientIDsByConnectionID.removeValue(forKey: id)
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
        if let ticket = ticketStore.validTicket(authToken: request.auth?.attachToken) {
            switch Self.ticketAuthorizationError(ticket: ticket, request: request) {
            case nil:
                return nil
            case let error?:
                if request.auth?.stackAccessToken == nil {
                    return .failure(error)
                }
                // A ticket is intentionally narrow. Same-account Stack auth can
                // still authorize broader operations such as creating workspaces.
            }
        }
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

    private static func ticketAuthorizationError(
        ticket: CmxAttachTicket,
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
        case "mobile.terminal.snapshot", "terminal.snapshot",
             "mobile.terminal.input", "terminal.input":
            return ticketTerminalAuthorizationError(
                ticket: ticket,
                workspaceSelection: workspaceSelection.value,
                terminalSelection: terminalSelection.value
            )
        case "mobile.host.status":
            return nil
        default:
            return scopedTicketError
        }
    }

    private static func ticketTerminalAuthorizationError(
        ticket: CmxAttachTicket,
        workspaceSelection: String?,
        terminalSelection: String?
    ) -> MobileHostRPCError? {
        if let workspaceSelection, workspaceSelection != ticket.workspaceID {
            return scopedTicketError
        }

        if let terminalID = ticket.terminalID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !terminalID.isEmpty {
            guard terminalSelection == terminalID else {
                return scopedTicketError
            }
            return nil
        }

        guard workspaceSelection == ticket.workspaceID else {
            return scopedTicketError
        }
        return nil
    }

    static func debugTicketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        ticketAuthorizationError(ticket: ticket, request: request)
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
        } else {
            let stack = StackClientApp(
                projectId: AuthEnvironment.stackProjectID,
                publishableClientKey: AuthEnvironment.stackPublishableClientKey,
                baseUrl: AuthEnvironment.stackBaseURL.absoluteString,
                tokenStore: .custom(MobileHostAccessTokenStore(accessToken: accessToken)),
                noAutomaticPrefetch: true
            )
            guard let user = try await Self.withVerificationTimeout({
                try await stack.getUser(or: .throw)
            }) else {
                throw MobileHostAuthorizationError.invalidStackUser
            }
            remoteUserID = await user.id
            cache[cacheKey] = CacheEntry(
                userID: remoteUserID,
                expiresAt: now.addingTimeInterval(60)
            )
        }

        let localUserID = await currentAuthenticatedLocalUserID()
        try MobileHostAuthorizationPolicy.authorizeStackUser(
            localUserID: localUserID,
            remoteUserID: remoteUserID
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
    private var didDecodeFirstFrame = false
    private var isClosed = false

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
                    await respond(to: frame)
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
        guard idleTimeoutNanoseconds > 0, didDecodeFirstFrame, !isClosed else {
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
        guard didDecodeFirstFrame else {
            return
        }
        close(reason: "idle after frame timed out")
    }

    private func respond(to frame: Data) async {
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
                _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: error))
                return
            }
            await onAuthorizedRequest(request)
            let result = await handleRequest(request)
            _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: request.id, result: result))
        case let .failure(error):
            _ = await sendResponse(MobileHostRPCEnvelope.encodeResponse(id: nil, result: .failure(error)))
            close(reason: "invalid rpc envelope")
        }
    }

    private static func isInteractiveMobileRequest(_ method: String) -> Bool {
        switch method {
        case "mobile.host.status", "mobile.terminal.snapshot", "terminal.snapshot":
            return false
        default:
            return true
        }
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
