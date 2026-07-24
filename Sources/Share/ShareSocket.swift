import CmuxWorkspaceShare
import Foundation
import os

nonisolated private let shareSocketLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "WorkspaceShareSocket"
)

/// Actor-isolated WebSocket transport for one host share session.
actor ShareSocket {
    enum SendResult: Equatable, Sendable {
        case admitted
        case invalid
        case backpressured

        var wasAdmitted: Bool {
            self == .admitted
        }
    }

    enum ConnectionSendResult: Equatable, Sendable {
        case admitted
        case invalid
        case backpressured
        case staleConnection
    }

    struct Endpoint: Sendable {
        let wsUrl: String
        let token: String
    }

    enum Event: Sendable {
        case opened(connection: UInt64)
        case text(String, connection: UInt64, sequence: UInt64)
        case connectionStateChanged(Bool)
        case stopped
    }

    private enum Outbound: Sendable {
        case text(String)
        case data(Data)

        var byteCount: Int {
            switch self {
            case .text(let text):
                return text.utf8.count
            case .data(let data):
                return data.count
            }
        }

        var message: URLSessionWebSocketTask.Message {
            switch self {
            case .text(let text):
                return .string(text)
            case .data(let data):
                return .data(data)
            }
        }
    }

    private struct PendingOutbound: Sendable {
        let outbound: Outbound
        let completion: CheckedContinuation<Bool, Never>?
    }

    private struct ConnectionAdmissionState: Sendable {
        var accepting = false
        var connection: UInt64?
    }

    nonisolated let events: AsyncStream<Event>

    private let eventContinuation: AsyncStream<Event>.Continuation
    nonisolated private let outboundWakeContinuation: AsyncStream<Void>.Continuation
    private let outboundWakeStream: AsyncStream<Void>
    nonisolated private let outboundMailbox:
        WorkspaceShareOutboundMailbox<PendingOutbound>
    private let initialEndpoint: Endpoint
    private let refreshEndpoint: @Sendable () async throws -> Endpoint
    private let lifecycle: WorkspaceShareSessionLifecycle
    nonisolated private let outboundValidator =
        WorkspaceShareOutboundMessageValidator()
    nonisolated private let connectionAdmission =
        OSAllocatedUnfairLock(initialState: ConnectionAdmissionState())

    private var runTask: Task<Void, Never>?
    private var outboundWakeTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isStopped = false
    private var didUseInitialEndpoint = false
    private var connectionNeedsHandshake = false
    private var nextConnectionGeneration: UInt64 = 1
    private var activeConnectionGeneration: UInt64?
#if DEBUG
    private var beforeCriticalBackpressureLifecycleStateForTesting:
        (@Sendable () async -> Void)?
    private var recordedCriticalBackpressureCancellationIDs:
        Set<ObjectIdentifier> = []
#endif

    init(
        endpoint: Endpoint,
        refresh: @escaping @Sendable () async throws -> Endpoint,
        lifecycle: WorkspaceShareSessionLifecycle = WorkspaceShareSessionLifecycle(),
        maximumPendingMessages: Int = 256,
        maximumPendingBytes: Int = 4 * 1_024 * 1_024,
        maximumBufferedEvents: Int = 512
    ) {
        let eventPair = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingOldest(max(1, maximumBufferedEvents))
        )
        let wakePair = AsyncStream.makeStream(
            of: Void.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.events = eventPair.stream
        self.eventContinuation = eventPair.continuation
        self.outboundWakeStream = wakePair.stream
        self.outboundWakeContinuation = wakePair.continuation
        self.outboundMailbox = WorkspaceShareOutboundMailbox(
            maximumMessages: maximumPendingMessages,
            maximumBytes: maximumPendingBytes,
            reservedControlMessages: 16,
            reservedControlBytes: 64 * 1_024,
            reservedAcknowledgementMessages: 128,
            reservedAcknowledgementBytes: 64 * 1_024
        )
        self.initialEndpoint = endpoint
        self.refreshEndpoint = refresh
        self.lifecycle = lifecycle
    }

    func start() {
        guard runTask == nil, !isStopped else { return }
        let outboundWakeStream = outboundWakeStream
        outboundWakeTask = Task { [weak self] in
            for await _ in outboundWakeStream {
                guard let self, !Task.isCancelled else { return }
                await self.startSendTaskIfNeeded()
            }
        }
        let lifecycle = lifecycle
        runTask = Task { [weak self] in
            await lifecycle.start()
            let states = await lifecycle.states()
            for await state in states {
                guard let self, !Task.isCancelled else { return }
                switch state {
                case .connecting(let attempt):
                    await self.connect(attempt: attempt)
                case .idle, .connected, .reconnecting:
                    continue
                case .stopped:
                    await self.emitPermanentStop()
                    return
                }
            }
        }
    }

    func stop() async {
        setConnectionAdmission(false)
        guard !isStopped else { return }
        isStopped = true
        await lifecycle.stop()
        runTask?.cancel()
        runTask = nil
        outboundWakeContinuation.finish()
        outboundWakeTask?.cancel()
        outboundWakeTask = nil
        sendTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        connectionNeedsHandshake = false
        activeConnectionGeneration = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        resumeDiscarded(outboundMailbox.stop())
        enqueueEvent(.connectionStateChanged(false))
        eventContinuation.finish()
    }

    @discardableResult
    private nonisolated func enqueueEvent(_ event: Event) -> Bool {
        switch eventContinuation.yield(event) {
        case .enqueued:
            return true
        case .dropped, .terminated:
            setConnectionAdmission(false)
            eventContinuation.finish()
            return false
        @unknown default:
            setConnectionAdmission(false)
            eventContinuation.finish()
            return false
        }
    }

#if DEBUG
    @discardableResult
    nonisolated func enqueueEventForTesting(_ event: Event) -> Bool {
        if case .connectionStateChanged(true) = event {
            setConnectionAdmission(true)
        }
        return enqueueEvent(event)
    }
#endif

    @discardableResult
    nonisolated func send(_ message: ShareHostMessage) -> SendResult {
        guard connectionAdmission.withLock({ $0.accepting }) else {
            return .backpressured
        }
        guard let message = outboundValidator.prepareForTransport(message),
              let (outbound, priority) = Self.encode(message) else {
            shareSocketLogger.error("Dropping an unencodable share protocol message")
            return .invalid
        }
        let accepted = connectionAdmission.withLock { admission in
            guard admission.accepting else { return false }
            return admit(outbound, priority: priority)
        }
        return accepted ? .admitted : .backpressured
    }

    /// Admits an ACK only while its source connection is still current.
    @discardableResult
    nonisolated func sendAcknowledgement(
        nonce: ShareAckNonce,
        connection: UInt64
    ) -> ConnectionSendResult {
        let message = ShareHostMessage.ack(nonce: nonce)
        guard let message = outboundValidator.prepareForTransport(message),
              let (outbound, _) = Self.encode(message) else {
            shareSocketLogger.error("Dropping an invalid share acknowledgement")
            return .invalid
        }
        return connectionAdmission.withLock { admission in
            guard admission.accepting,
                  admission.connection == connection else {
                return .staleConnection
            }
            return admit(outbound, priority: .acknowledgement)
                ? .admitted
                : .backpressured
        }
    }

    /// Atomically admits an accepted resync's ACK and required hello replay.
    @discardableResult
    nonisolated func sendAcknowledgementAndResyncHello(
        nonce: ShareAckNonce,
        shared: [ShareSharedWorkspace],
        layouts: [ShareWorkspaceLayout],
        connection: UInt64
    ) -> ConnectionSendResult {
        let acknowledgementMessage = ShareHostMessage.ack(nonce: nonce)
        let replayMessage = ShareHostMessage.hello(
            shared: shared,
            layouts: layouts
        )
        guard let acknowledgementMessage =
                outboundValidator.prepareForTransport(acknowledgementMessage),
              let replayMessage =
                outboundValidator.prepareForTransport(replayMessage),
              let (acknowledgementOutbound, _) =
                Self.encode(acknowledgementMessage),
              let (replayOutbound, _) = Self.encode(replayMessage) else {
            shareSocketLogger.error("Dropping an invalid share resync hello")
            return .invalid
        }
        let acknowledgement = PendingOutbound(
            outbound: acknowledgementOutbound,
            completion: nil
        )
        let replay = PendingOutbound(
            outbound: replayOutbound,
            completion: nil
        )
        let result = connectionAdmission.withLock { admission in
            guard admission.accepting,
                  admission.connection == connection else {
                return ConnectionSendResult.staleConnection
            }
            return outboundMailbox.admitAcknowledgementAndReplayAndRelease(
                acknowledgement: acknowledgement,
                acknowledgementByteCount: acknowledgementOutbound.byteCount,
                replay: replay,
                replayByteCount: replayOutbound.byteCount
            ) ? .admitted : .backpressured
        }
        guard result == .admitted else {
            if result == .backpressured {
                shareSocketLogger.warning(
                    "Rejecting an outbound resync replay at the bounded mailbox"
                )
            }
            return result
        }
        outboundWakeContinuation.yield(())
        return .admitted
    }

    @discardableResult
    nonisolated func send(data: Data) -> SendResult {
        guard connectionAdmission.withLock({ $0.accepting }) else {
            return .backpressured
        }
        guard data.count < ShareProtocolConstants.binaryFrameByteLimit,
              ShareBinaryFrame.decode(data) != nil else {
            shareSocketLogger.warning(
                "Dropping an invalid or oversized binary share frame"
            )
            return .invalid
        }
        let accepted = connectionAdmission.withLock { admission in
            guard admission.accepting else { return false }
            return admit(.data(data), priority: .bulk)
        }
        return accepted ? .admitted : .backpressured
    }

    /// Sends one final protocol message, waits until URLSession accepts it,
    /// and then permanently stops the socket.
    @discardableResult
    func sendAndStop(
        _ message: ShareHostMessage,
        connection: UInt64? = nil
    ) async -> Bool {
        guard let taskToStop = webSocketTask, !isStopped else {
            if connection == nil {
                await stop()
                return true
            }
            return false
        }
        if let connection,
           activeConnectionGeneration != connection {
            return false
        }
        if connection == nil {
            // Manual teardown owns the whole session. Close admission and
            // make its final message the only queued work so an unresolved
            // delivery-credit barrier cannot strand shutdown.
            setConnectionAdmission(false)
            resumeDiscarded(outboundMailbox.discardAll())
        }
        guard let message = outboundValidator.prepareForTransport(message),
              let (outbound, priority) = Self.encode(message) else {
            shareSocketLogger.error("Dropping an unencodable final share protocol message")
            await stop()
            return true
        }
        let finalPriority:
            WorkspaceShareOutboundMailbox<PendingOutbound>.Priority =
                connectionNeedsHandshake ? .handshake : priority
        _ = await withCheckedContinuation { continuation in
            let accepted = admit(
                outbound,
                priority: finalPriority,
                completion: continuation
            )
            if !accepted {
                continuation.resume(returning: false)
            }
        }
        if let connection {
            guard activeConnectionGeneration == connection,
                  webSocketTask === taskToStop else {
                return false
            }
        }
        await stop()
        return true
    }

    /// Resets reconnect escalation only when a validated snapshot belongs to
    /// the socket generation that is still active.
    func sessionSynchronized(connection: UInt64) async {
        guard !isStopped,
              webSocketTask != nil,
              activeConnectionGeneration == connection else {
            return
        }
        await lifecycle.sessionSynchronized()
    }

    /// Drops queued work and forces a fresh connection after critical
    /// flow-control work cannot enter the bounded mailbox.
    func reconnectAfterOutboundBackpressure(
        connection: UInt64
    ) async -> Bool {
        guard activeConnectionGeneration == connection else {
            shareSocketLogger.info(
                "Critical outbound backpressure joined a replacement connection"
            )
            return true
        }
        setConnectionAdmission(false)
        let discarded = outboundMailbox.discardAll()
        resumeDiscarded(discarded)
        guard !isStopped else {
            return false
        }
        let taskToCancel = webSocketTask
#if DEBUG
        if let hook = beforeCriticalBackpressureLifecycleStateForTesting {
            beforeCriticalBackpressureLifecycleStateForTesting = nil
            await hook()
        }
#endif
        let lifecycleState = await lifecycle.state
        guard !isStopped else {
            return false
        }
        switch lifecycleState {
        case .connecting, .connected, .reconnecting:
            break
        case .idle, .stopped:
            return false
        }
        guard activeConnectionGeneration == connection,
              let taskToCancel,
              webSocketTask === taskToCancel else {
            shareSocketLogger.info(
                "Critical outbound backpressure joined an existing reconnect"
            )
            return true
        }
        shareSocketLogger.error(
            "Reconnecting after critical outbound share backpressure"
        )
        sendTask?.cancel()
#if DEBUG
        recordedCriticalBackpressureCancellationIDs.insert(
            ObjectIdentifier(taskToCancel)
        )
#endif
        taskToCancel.cancel(with: .goingAway, reason: nil)
        return true
    }

#if DEBUG
    func installWebSocketTaskForTesting(
        _ task: URLSessionWebSocketTask,
        connection: UInt64
    ) {
        resumeDiscarded(outboundMailbox.discardAll())
        webSocketTask = task
        activeConnectionGeneration = connection
        setConnectionAdmission(true, connection: connection)
    }

    func currentWebSocketTaskIDForTesting() -> ObjectIdentifier? {
        webSocketTask.map(ObjectIdentifier.init)
    }

    func criticalBackpressureCancellationIDsForTesting()
        -> Set<ObjectIdentifier> {
        recordedCriticalBackpressureCancellationIDs
    }

    func hasPendingOutboundForTesting() -> Bool {
        outboundMailbox.hasPending
    }

    func completeNextOutboundForTesting() -> Bool {
        guard let claim = outboundMailbox.claimNext() else {
            return false
        }
        outboundMailbox.complete(claim)?
            .payload.completion?.resume(returning: true)
        return true
    }

    func isStoppedForTesting() -> Bool {
        isStopped
    }

    func setBeforeCriticalBackpressureLifecycleStateForTesting(
        _ hook: @escaping @Sendable () async -> Void
    ) {
        beforeCriticalBackpressureLifecycleStateForTesting = hook
    }
#endif

    /// Blocks ordinary outbound work behind the marker paired with an
    /// accepted server payload. A second payload displaces and drops the
    /// unresolved batch.
    @discardableResult
    nonisolated func beginAcknowledgementBarrier(
        connection: UInt64
    ) -> Bool {
        let result: (
            accepted: Bool,
            discarded: [
                WorkspaceShareOutboundMailbox<PendingOutbound>.Entry
            ]
        ) = connectionAdmission.withLock { admission in
            guard admission.accepting,
                  admission.connection == connection else {
                return (false, [])
            }
            return (
                true,
                outboundMailbox.beginAcknowledgementBarrier()
            )
        }
        guard result.accepted else { return false }
        let discarded = result.discarded
        if !discarded.isEmpty {
            shareSocketLogger.warning(
                "Dropping outbound share work displaced before its acknowledgement marker"
            )
            resumeDiscarded(discarded)
        }
        return true
    }

    /// Fails closed for an invalid, orphaned, or non-adjacent marker.
    @discardableResult
    nonisolated func discardAcknowledgementBarrier(
        connection: UInt64
    ) -> Bool {
        let result: (
            accepted: Bool,
            discarded: [
                WorkspaceShareOutboundMailbox<PendingOutbound>.Entry
            ]
        ) = connectionAdmission.withLock { admission in
            guard admission.accepting,
                  admission.connection == connection else {
                return (false, [])
            }
            return (
                true,
                outboundMailbox.discardAcknowledgementBarrier()
            )
        }
        guard result.accepted else { return false }
        let discarded = result.discarded
        if !discarded.isEmpty {
            shareSocketLogger.warning(
                "Dropping outbound share work behind an unresolved acknowledgement marker"
            )
            resumeDiscarded(discarded)
        }
        if outboundMailbox.hasClaimablePending {
            outboundWakeContinuation.yield(())
        }
        return true
    }

    @discardableResult
    private nonisolated func admit(
        _ outbound: Outbound,
        priority: WorkspaceShareOutboundMailbox<PendingOutbound>.Priority,
        completion: CheckedContinuation<Bool, Never>? = nil
    ) -> Bool {
        let pending = PendingOutbound(
            outbound: outbound,
            completion: completion
        )
        let accepted: Bool
        if priority == .acknowledgement {
            accepted = outboundMailbox.admitAcknowledgementAndRelease(
                pending,
                byteCount: outbound.byteCount
            )
        } else {
            accepted = outboundMailbox.admit(
                pending,
                byteCount: outbound.byteCount,
                priority: priority
            )
        }
        guard accepted else {
            shareSocketLogger.warning(
                "Rejecting an outbound share frame at the bounded mailbox"
            )
            return false
        }
        outboundWakeContinuation.yield(())
        return true
    }

    private func startSendTaskIfNeeded() {
        guard sendTask == nil,
              webSocketTask != nil,
              (!connectionNeedsHandshake
                  || outboundMailbox.hasHandshakePending),
              outboundMailbox.hasClaimablePending else {
            return
        }
        sendTask = Task { [weak self] in
            await self?.drainOutboundMailbox()
        }
    }

    private func drainOutboundMailbox() async {
        defer {
            sendTask = nil
            startSendTaskIfNeeded()
        }
        while !Task.isCancelled, !isStopped,
              let task = webSocketTask,
              let claim = outboundMailbox.claimNext() {
            let outbound = claim.entry.payload.outbound
            do {
                try await task.send(outbound.message)
                if claim.entry.priority == .handshake {
                    connectionNeedsHandshake = false
                }
                outboundMailbox.complete(claim)?
                    .payload.completion?.resume(returning: true)
            } catch {
                outboundMailbox.complete(claim)?
                    .payload.completion?.resume(returning: false)
                resumeDiscarded(outboundMailbox.discardAll())
                shareSocketLogger.warning(
                    "A queued share frame failed; reconnecting the share socket"
                )
                task.cancel(with: .goingAway, reason: nil)
                return
            }
        }
    }

    private func connect(attempt: Int) async {
        guard !isStopped else { return }
        let endpoint: Endpoint
        do {
            if didUseInitialEndpoint {
                endpoint = try await refreshEndpoint()
            } else {
                endpoint = initialEndpoint
                didUseInitialEndpoint = true
            }
        } catch {
            shareSocketLogger.warning(
                "Refreshing share credentials failed on connection attempt \(attempt, privacy: .public)"
            )
            let failure = (error as? ShareSessionAPIError)?.lifecycleFailure
                ?? .transport
            await lifecycle.connectionFailed(failure)
            return
        }

        guard let request = Self.connectionRequest(endpoint: endpoint) else {
            shareSocketLogger.error("The share WebSocket endpoint was invalid")
            await lifecycle.connectionFailed(.invalidEndpoint)
            return
        }

        let delegate = ShareSocketOpenDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let socketTask = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = socketTask
        connectionNeedsHandshake = true
        socketTask.resume()

        var openEvents = delegate.events.makeAsyncIterator()
        guard let openEvent = await openEvents.next(), !isStopped else {
            closeCurrentConnection(session: session, task: socketTask)
            return
        }

        switch openEvent {
        case .opened:
            let staleEntries = outboundMailbox.discardAll()
            if !staleEntries.isEmpty {
                shareSocketLogger.info(
                    "Discarding stale outbound work before a connection hello"
                )
                resumeDiscarded(staleEntries)
            }
            await lifecycle.connectionOpened()
            let connection = nextConnectionGeneration
            nextConnectionGeneration &+= 1
            activeConnectionGeneration = connection
            setConnectionAdmission(true, connection: connection)
            guard enqueueEvent(.connectionStateChanged(true)),
                  enqueueEvent(.opened(connection: connection)) else {
                shareSocketLogger.error(
                    "Closing a share socket whose event consumer fell behind"
                )
                socketTask.cancel(with: .goingAway, reason: nil)
                closeCurrentConnection(session: session, task: socketTask)
                guard !isStopped else { return }
                await lifecycle.connectionFailed(
                    .webSocketClosed(code: 1_001, reason: nil)
                )
                return
            }
            startSendTaskIfNeeded()
            let failure = await receiveLoop(
                socketTask,
                connection: connection
            )
            setConnectionAdmission(false)
            enqueueEvent(.connectionStateChanged(false))
            closeCurrentConnection(session: session, task: socketTask)
            guard !isStopped else { return }
            await lifecycle.connectionFailed(failure)
        case .closed(let code, let reason):
            closeCurrentConnection(session: session, task: socketTask)
            await lifecycle.connectionFailed(
                .webSocketClosed(code: code, reason: reason)
            )
        case .failed:
            closeCurrentConnection(session: session, task: socketTask)
            await lifecycle.connectionFailed(.transport)
        }
    }

    private func receiveLoop(
        _ task: URLSessionWebSocketTask,
        connection: UInt64
    ) async -> WorkspaceShareSessionLifecycle.Failure {
        var sequence: UInt64 = 0
        while !Task.isCancelled, !isStopped {
            do {
                switch try await task.receive() {
                case .string(let text):
                    let byteCount = text.utf8.count
                    guard WorkspaceShareTextFramePolicy.acceptsServerFrame(
                        byteCount: byteCount
                    ) else {
                        shareSocketLogger.warning(
                            "Closing a share socket after an oversized server text frame"
                        )
                        task.cancel(with: .messageTooBig, reason: nil)
                        return .webSocketClosed(
                            code: ShareProtocolConstants.messageTooBigCloseCode,
                            reason: nil
                        )
                    }
                    guard enqueueEvent(.text(
                        text,
                        connection: connection,
                        sequence: sequence
                    )) else {
                        shareSocketLogger.error(
                            "Closing a share socket whose event consumer fell behind"
                        )
                        task.cancel(with: .goingAway, reason: nil)
                        return .webSocketClosed(code: 1_001, reason: nil)
                    }
                case .data(let data):
                    guard data.count < ShareProtocolConstants.binaryFrameByteLimit else {
                        shareSocketLogger.warning(
                            "Closing a share socket after an oversized server binary frame"
                        )
                        task.cancel(with: .messageTooBig, reason: nil)
                        return .webSocketClosed(
                            code: ShareProtocolConstants.messageTooBigCloseCode,
                            reason: nil
                        )
                    }
                    // Hosts do not consume server binary messages. Counting
                    // this frame creates a sequence gap, so a following marker
                    // cannot acknowledge an earlier accepted JSON payload.
                    break
                @unknown default:
                    break
                }
                guard sequence < UInt64.max else {
                    return .webSocketClosed(code: 1_008, reason: nil)
                }
                sequence += 1
            } catch {
                shareSocketLogger.info("The share receive loop ended")
                let code = Int(task.closeCode.rawValue)
                let reason = ShareSocketOpenDelegate.boundedCloseReason(
                    task.closeReason
                )
                return code == 0
                    ? .transport
                    : .webSocketClosed(code: code, reason: reason)
            }
        }
        return .cancelled
    }

    private func closeCurrentConnection(
        session: URLSession,
        task: URLSessionWebSocketTask
    ) {
        if webSocketTask === task {
            setConnectionAdmission(false)
            sendTask?.cancel()
            webSocketTask = nil
            connectionNeedsHandshake = false
            activeConnectionGeneration = nil
            urlSession = nil
            resumeDiscarded(outboundMailbox.discardAll())
        }
        session.invalidateAndCancel()
    }

    private nonisolated func resumeDiscarded(
        _ entries: [
            WorkspaceShareOutboundMailbox<PendingOutbound>.Entry
        ]
    ) {
        for entry in entries {
            entry.payload.completion?.resume(returning: false)
        }
    }

    private func emitPermanentStop() {
        setConnectionAdmission(false)
        enqueueEvent(.connectionStateChanged(false))
        enqueueEvent(.stopped)
        eventContinuation.finish()
    }

    nonisolated static func connectionRequest(endpoint: Endpoint) -> URLRequest? {
        guard WorkspaceShareGrantValidator.isValidToken(endpoint.token),
              let validatedURL = WorkspaceShareGrantValidator.webSocketURL(
                from: endpoint.wsUrl
              ),
              var components = URLComponents(
                url: validatedURL,
                resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "token" }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url,
              WorkspaceShareGrantValidator.webSocketURL(
                from: url.absoluteString
              ) != nil else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(endpoint.token)",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    private nonisolated static func encode(
        _ message: ShareHostMessage
    ) -> (
        Outbound,
        WorkspaceShareOutboundMailbox<PendingOutbound>.Priority
    )? {
        guard let data = try? JSONEncoder().encode(message),
              WorkspaceShareTextFramePolicy.acceptsHostFrame(byteCount: data.count),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let priority: WorkspaceShareOutboundMailbox<PendingOutbound>.Priority
        switch message {
        case .hello:
            priority = .handshake
        case .ack:
            priority = .acknowledgement
        default:
            priority = .control
        }
        return (.text(text), priority)
    }

    deinit {
        setConnectionAdmission(false)
        runTask?.cancel()
        outboundWakeContinuation.finish()
        outboundWakeTask?.cancel()
        sendTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        resumeDiscarded(outboundMailbox.stop())
        eventContinuation.finish()
    }

    private nonisolated func setConnectionAdmission(
        _ accepting: Bool,
        connection: UInt64? = nil
    ) {
        connectionAdmission.withLock { admission in
            admission.accepting = accepting
            admission.connection = accepting ? connection : nil
        }
    }
}
