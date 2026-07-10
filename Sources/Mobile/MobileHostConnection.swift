import CMUXMobileCore
import Foundation
import OSLog

private let mobileHostConnectionLog = Logger(subsystem: "dev.cmux", category: "mobile-host")

actor MobileHostConnection {
    private static let maximumReceiveBufferByteCount = MobileSyncFrameCodec.defaultMaximumFrameByteCount + MobileSyncFrameCodec.headerByteCount
    private static let defaultFirstFrameTimeoutNanoseconds: UInt64 = 15 * 1_000_000_000
    private static let defaultIdleTimeoutNanoseconds: UInt64 = 30 * 1_000_000_000
    private static let defaultMaximumInFlightRequestCount = 16

    private let id: UUID
    private let byteConnection: any MobileHostByteConnection
    private let firstFrameTimeoutNanoseconds: UInt64
    private let idleTimeoutNanoseconds: UInt64
    private let maximumInFlightRequestCount: Int
    private let authorizeRequest: @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult?
    private let onAuthorizedRequest: @Sendable (MobileHostRPCRequest) async -> Void
    private let handleRequest: @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult
    private let onClose: @Sendable (UUID) async -> Void
    private var receiveBuffer = Data()
    private var firstFrameTimeoutTask: Task<Void, Never>?
    private var idleTimeoutTask: Task<Void, Never>?
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var responseSlotsInUse = 0
    private var responseSlotWaiters: [CheckedContinuation<Void, Never>] = []
    private var didDecodeFirstFrame = false
    private var isClosed = false
    /// stream_id -> set of topics this connection is subscribed to.
    /// Populated by `mobile.events.subscribe`; cleared on close.
    private var subscriptions: [String: Set<String>] = [:]

    init(
        id: UUID,
        byteConnection: any MobileHostByteConnection,
        firstFrameTimeoutNanoseconds: UInt64 = MobileHostConnection.defaultFirstFrameTimeoutNanoseconds,
        idleTimeoutNanoseconds: UInt64 = MobileHostConnection.defaultIdleTimeoutNanoseconds,
        maximumInFlightRequestCount: Int = MobileHostConnection.defaultMaximumInFlightRequestCount,
        authorizeRequest: @escaping @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult?,
        onAuthorizedRequest: @escaping @Sendable (MobileHostRPCRequest) async -> Void,
        handleRequest: @escaping @Sendable (MobileHostRPCRequest) async -> MobileHostRPCResult,
        onClose: @escaping @Sendable (UUID) async -> Void
    ) {
        self.id = id
        self.byteConnection = byteConnection
        self.firstFrameTimeoutNanoseconds = firstFrameTimeoutNanoseconds
        self.idleTimeoutNanoseconds = idleTimeoutNanoseconds
        self.maximumInFlightRequestCount = max(1, maximumInFlightRequestCount)
        self.authorizeRequest = authorizeRequest
        self.onAuthorizedRequest = onAuthorizedRequest
        self.handleRequest = handleRequest
        self.onClose = onClose
    }

    func start() {
        byteConnection.start(
            onEvent: { [weak self, id] event in
                guard let self else { return }
                Task { await self.handleEvent(event, connectionID: id) }
            },
            onReceive: { [weak self] data, isComplete, errorDescription in
                guard let self else { return }
                Task {
                    await self.handleReceive(
                        data: data,
                        isComplete: isComplete,
                        errorDescription: errorDescription
                    )
                }
            }
        )
        startFirstFrameTimeout()
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
        responseSlotsInUse = 0
        let waiters = responseSlotWaiters
        responseSlotWaiters.removeAll()
        for task in tasks {
            task.cancel()
        }
        for waiter in waiters {
            waiter.resume()
        }
        let previousSubscriptions = Array(subscriptions.values)
        subscriptions.removeAll()
        for topics in previousSubscriptions where !topics.isEmpty {
            MobileHostEventSubscriptionTracker.replace(
                previousTopics: topics,
                nextTopics: nil
            )
        }
        mobileHostConnectionLog.info("mobile host connection closed \(self.id.uuidString, privacy: .public): \(reason, privacy: .public)")
        byteConnection.close()
        Task { await onClose(id) }
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
                    await startResponseTask(for: frame)
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
        } else if !isClosed {
            byteConnection.resumeReceiving()
        }
    }

    private func startResponseTask(for frame: Data) async {
        guard !isClosed else {
            return
        }
        await reserveResponseSlot()
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
        responseSlotsInUse = max(0, responseSlotsInUse - 1)
        resumeNextResponseSlotWaiterIfPossible()
        if responseTasks.isEmpty {
            startIdleTimeout()
        }
    }

    private func reserveResponseSlot() async {
        guard !isClosed else { return }
        if responseSlotsInUse < maximumInFlightRequestCount {
            responseSlotsInUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            responseSlotWaiters.append(continuation)
        }
    }

    private func resumeNextResponseSlotWaiterIfPossible() {
        guard !isClosed,
              responseSlotsInUse < maximumInFlightRequestCount,
              !responseSlotWaiters.isEmpty else {
            return
        }
        responseSlotsInUse += 1
        let waiter = responseSlotWaiters.removeFirst()
        waiter.resume()
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

        if let errorDescription = await byteConnection.send(frame) {
            close(reason: errorDescription)
            return false
        }
        return true
    }

    private func handleEvent(_ event: MobileHostByteConnectionEvent, connectionID: UUID) {
        switch event {
        case .failed(let reason):
            close(reason: reason)
        case .cancelled:
            close(reason: "cancelled")
        case .ready:
            mobileHostConnectionLog.debug("mobile host connection ready \(connectionID.uuidString, privacy: .public)")
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
