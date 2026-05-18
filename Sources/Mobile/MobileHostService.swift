import CMUXMobileCore
import Foundation
@preconcurrency import Network
import OSLog
import StackAuth

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

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
    private static let maximumActiveConnectionCount = 10

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

    private init() {}

    func start() {
        guard listener == nil else {
            return
        }

        startListener(usePreferredPort: true)
    }

    private func startListener(usePreferredPort: Bool) {
        do {
            let parameters = NWParameters.tcp
            let nextListener = try makeListener(parameters: parameters, usePreferredPort: usePreferredPort)
            let generation = UUID()
            listenerGeneration = generation
            nextListener.stateUpdateHandler = { state in
                Task { @MainActor in
                    MobileHostService.shared.handleListenerState(state, generation: generation)
                }
            }
            nextListener.newConnectionHandler = { connection in
                Task { @MainActor in
                    MobileHostService.shared.accept(connection, generation: generation)
                }
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
        activeConnections.removeAll()
        clientIDsByConnectionID.removeAll()
        TerminalController.shared.clearAllMobileViewportReports(reason: "mobile.host.stopped")
    }

    func statusSnapshot() -> MobileHostServiceStatus {
        let routes = listenerPort.map { routeResolver.routes(port: $0).routes } ?? []
        return MobileHostServiceStatus(
            isRunning: listener != nil && listenerPort != nil,
            port: listenerPort,
            routes: routes,
            activeConnectionCount: activeConnections.count,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func publicStatusSnapshot() async -> MobileHostServiceStatus {
        let routes: [CmxAttachRoute]
        if let listenerPort {
            routes = await routeResolver.routesResolvingTailscaleDNS(port: listenerPort).routes
        } else {
            routes = []
        }
        return MobileHostServiceStatus(
            isRunning: listener != nil && listenerPort != nil,
            port: listenerPort,
            routes: routes,
            activeConnectionCount: activeConnections.count,
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

    func createAttachTicket(
        workspaceID: String,
        terminalID: String?,
        ttl: TimeInterval
    ) async throws -> [String: Any] {
        let routes: [CmxAttachRoute]
        if let listenerPort {
            routes = await routeResolver.routesResolvingTailscaleDNS(port: listenerPort).routes
        } else {
            routes = []
        }
        let ticket = try ticketStore.createTicket(
            workspaceID: workspaceID,
            terminalID: terminalID,
            routes: routes,
            ttl: ttl
        )
        return try ticketStore.payload(for: ticket)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard listener != nil, generation == listenerGeneration else {
            connection.cancel()
            return
        }
        guard activeConnections.count < Self.maximumActiveConnectionCount else {
            mobileHostLog.error("mobile host rejected connection because active connection limit was reached")
            connection.cancel()
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
        activeConnections.removeValue(forKey: id)
        clientIDsByConnectionID.removeValue(forKey: id)
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
        do {
            try await MobileHostStackAuthVerifier.shared.verify(auth: request.auth)
            return nil
        } catch {
            mobileHostLog.error("mobile host authorization failed method=\(request.method, privacy: .public) error=\(String(describing: error), privacy: .public)")
            return .failure(MobileHostRPCError(
                code: "unauthorized",
                message: "Mobile sync authorization failed."
            ))
        }
    }

    private static func ticketAuthorizationError(
        ticket: CmxAttachTicket,
        request: MobileHostRPCRequest
    ) -> MobileHostRPCError? {
        let workspaceID = stringParam(request.params, keys: ["workspace_id"])
        let terminalSelection = stringParamSelection(
            request.params,
            keys: ["surface_id", "terminal_id", "tab_id"]
        )
        if terminalSelection.hasConflict {
            return scopedTicketError
        }
        let terminalID = terminalSelection.value

        switch request.method {
        case "mobile.workspace.list", "workspace.list":
            guard workspaceID == ticket.workspaceID else {
                return scopedTicketError
            }
            if let ticketTerminalID = ticket.terminalID {
                guard terminalID == ticketTerminalID else {
                    return scopedTicketError
                }
            }
        case "mobile.terminal.create", "terminal.create":
            guard workspaceID == ticket.workspaceID else {
                return scopedTicketError
            }
            guard ticket.terminalID == nil else {
                return scopedTicketError
            }
        case "mobile.terminal.snapshot", "terminal.snapshot",
             "mobile.terminal.input", "terminal.input":
            guard workspaceID == ticket.workspaceID else {
                return scopedTicketError
            }
            if let ticketTerminalID = ticket.terminalID {
                guard terminalID == ticketTerminalID else {
                    return scopedTicketError
                }
            }
        case "mobile.host.status":
            return nil
        default:
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

    private static func stringParam(_ params: [String: Any], keys: [String]) -> String? {
        stringParamSelection(params, keys: keys).value
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

    private static func requiresAuthorization(method: String) -> Bool {
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
            routeResolver.refreshTailscaleRoutes()
            mobileHostLog.info("mobile host listener ready on port \(self.listenerPort ?? 0)")
        case let .failed(error):
            lastErrorDescription = String(describing: error)
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
        case .setup, .waiting:
            listenerPort = nil
        @unknown default:
            break
        }
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
}
#endif

private enum MobileHostAuthorizationError: Error {
    case missingStackTokens
    case invalidStackUser
    case missingLocalUser
    case accountMismatch
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

private actor MobileHostStackAuthVerifier {
    static let shared = MobileHostStackAuthVerifier()

    private struct CacheEntry {
        let userID: String
        let expiresAt: Date
    }

    private var cache: [String: CacheEntry] = [:]

    func verify(auth: MobileHostRPCAuth?) async throws {
        guard let accessToken = auth?.stackAccessToken else {
            throw MobileHostAuthorizationError.missingStackTokens
        }

        let cacheKey = accessToken
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
            guard let user = try await stack.getUser(or: .throw) else {
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
    private var idleTimeoutTimer: DispatchSourceTimer?
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
        idleTimeoutTimer?.cancel()
        idleTimeoutTimer = nil
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
            idleTimeoutTimer?.cancel()
            idleTimeoutTimer = nil
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
        idleTimeoutTimer?.cancel()
        let timeoutNanoseconds = min(idleTimeoutNanoseconds, UInt64(Int.max))
        let timer = DispatchSource.makeTimerSource(queue: callbackQueue)
        timer.schedule(deadline: .now() + .nanoseconds(Int(timeoutNanoseconds)))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.closeIfIdleAfterFrame() }
        }
        idleTimeoutTimer = timer
        timer.resume()
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
