import CMUXMobileCore
import Foundation
@preconcurrency import Network
import OSLog
import os

private let mobileHostLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

// JSONSerialization payloads are Foundation value containers. Requests are
// decoded once, treated as immutable, and then passed across actor boundaries.
struct MobileHostRPCRequest: @unchecked Sendable {
    let id: Any?
    let method: String
    let params: [String: Any]
    let auth: MobileHostRPCAuth?
}

// Authentication fields are plain immutable strings after envelope decoding.
struct MobileHostRPCAuth: @unchecked Sendable {
    let attachToken: String?
    let stackAccessToken: String?
}

// Error data is normalized through MobileHostRPCEnvelope.jsonValue before it is
// encoded back onto the wire.
struct MobileHostRPCError: Error, @unchecked Sendable {
    let code: String
    let message: String
    let data: Any?

    init(code: String, message: String, data: Any? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

enum MobileHostRPCResult: @unchecked Sendable {
    case ok(Any)
    case failure(MobileHostRPCError)
}

enum MobileHostRPCEnvelope {
    static func decodeRequest(_ data: Data) -> Result<MobileHostRPCRequest, MobileHostRPCError> {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .failure(MobileHostRPCError(code: "parse_error", message: "Invalid JSON"))
        }

        guard let dict = object as? [String: Any] else {
            return .failure(MobileHostRPCError(code: "invalid_request", message: "Expected JSON object"))
        }

        let method = (dict["method"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !method.isEmpty else {
            return .failure(MobileHostRPCError(code: "invalid_request", message: "Missing method"))
        }

        let params: [String: Any]
        if let rawParams = dict["params"] {
            guard let paramsObject = rawParams as? [String: Any] else {
                return .failure(MobileHostRPCError(code: "invalid_request", message: "params must be an object"))
            }
            params = paramsObject
        } else {
            params = [:]
        }

        let auth: MobileHostRPCAuth?
        if let rawAuth = dict["auth"] {
            guard let authObject = rawAuth as? [String: Any] else {
                return .failure(MobileHostRPCError(code: "invalid_request", message: "auth must be an object"))
            }
            auth = decodeAuth(authObject)
        } else {
            auth = nil
        }

        return .success(
            MobileHostRPCRequest(
                id: dict["id"],
                method: method,
                params: params,
                auth: auth
            )
        )
    }

    static func encodeResponse(id: Any?, result: MobileHostRPCResult) -> Data {
        switch result {
        case let .ok(payload):
            return jsonData([
                "id": jsonValue(id),
                "ok": true,
                "result": jsonValue(payload)
            ])
        case let .failure(error):
            var errorPayload: [String: Any] = [
                "code": error.code,
                "message": error.message
            ]
            if let data = error.data {
                errorPayload["data"] = jsonValue(data)
            }
            return jsonData([
                "id": jsonValue(id),
                "ok": false,
                "error": errorPayload
            ])
        }
    }

    static func ok(id: Any?, _ payload: Any) -> Data {
        encodeResponse(id: id, result: .ok(payload))
    }

    static func error(id: Any?, code: String, message: String, data: Any? = nil) -> Data {
        encodeResponse(
            id: id,
            result: .failure(MobileHostRPCError(code: code, message: message, data: data))
        )
    }

    private static func jsonValue(_ value: Any?) -> Any {
        guard let value else {
            return NSNull()
        }
        if JSONSerialization.isValidJSONObject(["value": value]) {
            return value
        }
        return String(describing: value)
    }

    private static func jsonData(_ object: Any) -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return Data(
                #"{"id":null,"ok":false,"error":{"code":"encode_error","message":"Failed to encode JSON"}}"#.utf8
            )
        }
        return data
    }

    private static func decodeAuth(_ auth: [String: Any]?) -> MobileHostRPCAuth? {
        guard let auth else {
            return nil
        }
        let attachToken = nonEmptyString(auth["attach_token"])
        let accessToken = nonEmptyString(auth["stack_access_token"])
        guard attachToken != nil || accessToken != nil else {
            return nil
        }
        return MobileHostRPCAuth(
            attachToken: attachToken,
            stackAccessToken: accessToken
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// The live set of accepted ``MobileHostConnection``s, keyed by connection id.
///
/// Single owner of the host's active-connection state: it backs
/// `MobileHostServiceStatus.activeConnectionCount`, enforces the accept-time
/// connection cap, and snapshots the connections for event fan-out. Held by
/// `MobileHostService` as a constructor-injected instance (no `static let
/// shared`); the lock keeps it `Sendable` so the service's `nonisolated static`
/// `emitEvent` forwarder can snapshot it without hopping to the main actor.
///
/// `@unchecked Sendable` is justified: the only mutable state is `connections`,
/// and every access is guarded by `lock`.
final class MobileHostConnectionRegistry: @unchecked Sendable {
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

/// One framed mobile-sync connection accepted by `MobileHostService`.
///
/// Owns the per-connection receive loop, first-frame/idle timeouts, per-frame
/// response tasks, and the connection's subscription state. Every collaborator
/// is injected so the actor has zero reach into `MobileHostService` internals:
/// authorization, post-authorization side effects, request handling, and close
/// notification arrive as `@Sendable` closures, and the cross-connection
/// per-topic subscription refcounts live in the injected
/// `MobileHostEventSubscriptionRegistry`. Wire framing goes through
/// `MobileSyncFrameCodec`.
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
    /// Injected per connection by `MobileHostService`. Owns the cross-connection
    /// per-topic subscription refcounts that gate server-pushed event delivery.
    private let eventSubscriptionRegistry: MobileHostEventSubscriptionRegistry
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
        onClose: @escaping @Sendable (UUID) async -> Void,
        eventSubscriptionRegistry: MobileHostEventSubscriptionRegistry
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
        self.eventSubscriptionRegistry = eventSubscriptionRegistry
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
            eventSubscriptionRegistry.replace(
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
                MobileHostService.beginRequest()
            }
            defer {
                if tracksInteractiveActivity {
                    MobileHostService.endRequest()
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
        eventSubscriptionRegistry.replace(
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
            eventSubscriptionRegistry.replace(previousTopics: previousTopics, nextTopics: nil)
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
