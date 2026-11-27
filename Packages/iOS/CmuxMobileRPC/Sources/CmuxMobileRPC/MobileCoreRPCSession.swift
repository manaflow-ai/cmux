internal import CMUXMobileCore
import Foundation

actor MobileCoreRPCSession {
    typealias TransportFactory = @Sendable () throws -> any CmxByteTransport
    typealias IndependentEventByteStreamFactory = @Sendable () async throws -> CmxIndependentEventByteStream
    typealias ConnectedCandidateHook = @Sendable (_ candidate: any CmxByteTransport) async -> Void
    typealias TransportConnectObserver = @Sendable (MobileRPCTransportConnectEvent) -> Void
    typealias TearDownRegistrationHook = @Sendable () async -> Void
    enum PendingRequestSettlement {
        case response(Result<Data, MobileShellConnectionError>)
        case cancelled
    }
    enum PipelinedRequestSettlement {
        case pending
        case awaiting(PendingContinuation)
        case settled(PendingRequestSettlement)
    }
    typealias PendingContinuation = CheckedContinuation<PendingRequestSettlement, Never>
    typealias ConnectingTask = (
        id: UUID,
        lease: MobileRPCConnectAttemptLease?,
        task: Task<any CmxByteTransport, any Error>,
        cancellationClose: MobileRPCConnectCancellationClose,
        diagnosticAttemptID: Int?,
        diagnosticStartedAt: ContinuousClock.Instant?,
        waiters: Set<UUID>,
        completed: Bool
    )
    static let defaultAbandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000
    static let defaultLateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000
    static let defaultCancelledWriteCompletionGraceNanoseconds: UInt64 = 250_000_000
    static let maximumDecodedFrameCountPerRead = 256

    struct EventSubscription {
        let id: UUID
        let stream: AsyncStream<MobileEventEnvelope>
    }

    struct EventListener {
        let topics: Set<String>
        let continuation: AsyncStream<MobileEventEnvelope>.Continuation
    }

    struct PendingWrite: Sendable {
        let id: UUID
        let requestID: String
        let frame: Data
    }

    struct WrittenControlFrame: Sendable {
        let frame: Data
        let generation: UInt64
        let sequence: UInt64
    }

    struct ActiveWrite: Sendable {
        let connectionID: UUID
        let requestID: String
        /// Resolves to the control-stream generation the frame was written
        /// to, or `nil` for transports that cannot replace their stream.
        let task: Task<UInt64?, any Error>
        var cancelledRequestResolutionTask: Task<Void, Never>?
    }

    struct IndependentEventPreparation: Sendable {
        let id: UUID
        let task: Task<CmxIndependentEventByteStream, any Error>
    }

    struct IndependentEventReader: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }

    let taskTimeout = RPCTaskTimeout()
    let connectAttemptKey: MobileRPCConnectAttemptKey?
    let connectAttemptRegistry: MobileRPCConnectAttemptRegistry
    let abandonedConnectCleanupTimeoutNanoseconds: UInt64
    let lateAbandonedConnectCloseTimeoutNanoseconds: UInt64
    let cancelledWriteCompletionGraceNanoseconds: UInt64
    let makeTransport: TransportFactory
    let makeIndependentEventByteStream: IndependentEventByteStreamFactory?
    let didReceiveConnectedCandidate: ConnectedCandidateHook?
    let diagnosticTransport: DiagnosticTransportKind?
    let transportConnectObserver: TransportConnectObserver?
    let tearDownRegistrationHook: TearDownRegistrationHook?
    /// Current shell ownership role. Connected transports that support role
    /// rebinding receive updates without replacing their admitted session.
    var transportSessionPurpose: CmxTransportSessionPurpose?
    // The getter is internal so the debug-only release-gate extension can
    // inspect the installed transport. Only this actor's production code can
    // replace it.
    var transport: (any CmxByteTransport)?
    /// The global physical-resource lease stays live for the installed
    /// transport's full lifetime. Teardown transfers it to the exact close
    /// task, so a hanging installed close consumes the same bounded cleanup
    /// budget as an abandoned connect.
    var installedConnectLease: MobileRPCConnectAttemptLease?
    var connectionTask: ConnectingTask?
    var recordedConnectCancellationAttemptIDs: Set<Int> = []
    var installedConnectionID: UUID?
    /// Counts inbound deliveries on the installed transport.
    ///
    /// A QUIC path can stop carrying traffic without closing: `receive()`
    /// never returns and never throws, so `readLoop` cannot tear the
    /// connection down and every request rides it until its own deadline.
    /// Comparing this counter across a request's lifetime answers the one
    /// question that separates "this request is slow" from "this transport is
    /// dead": did anything at all arrive while it was outstanding.
    var inboundDeliveryCount: UInt64 = 0
    /// Consecutive response timeouts that saw no inbound delivery at all.
    ///
    /// One unanswered request is genuinely ambiguous: a host can be slow or
    /// silent on a single method while its connection is perfectly healthy,
    /// and `responseTimeoutDoesNotCloseMultiplexedSession` pins that. Two in a
    /// row without a single byte arriving in between is not ambiguous. Any
    /// inbound delivery resets this, so the streak only survives a lane that
    /// has gone completely quiet.
    var silentTimeoutStreak = 0
    /// Increments once per counted silent timeout.
    ///
    /// Requests armed before the previous silent timeout belong to the same
    /// silence window. Six replays fired together and answered by one quiet
    /// period is one piece of evidence, not six, so only a request armed
    /// after the last counted timeout may advance the streak.
    var silentTimeoutEpoch: UInt64 = 0
    /// Silent timeouts required before the installed transport is condemned.
    static let minimumSilentTimeoutsBeforeCondemning = 2
    /// Control-stream replacements allowed on one connection before one of
    /// them is verified by a host answer. A replacement that is not verified
    /// escalates to close-and-redial, so this caps replacement at one
    /// attempt per silence episode and can never loop.
    static let maximumUnverifiedControlStreamRepairs = 1
    /// Upper bound on how long a replacement stream may take to answer its
    /// verification probe. The effective deadline is also capped by the
    /// timed-out request's own budget, so a short-deadline caller never waits
    /// longer for verification than it waited for its request.
    static let maximumControlStreamRepairVerificationNanoseconds: UInt64 = 5_000_000_000
    /// Frames written to the control stream that still await a response,
    /// keyed by request ID. Only kept for transports that can replace their
    /// stream: they are the requests a replacement may strand.
    var writtenControlFrames: [String: WrittenControlFrame] = [:]
    var writtenControlFrameSequence: UInt64 = 0
    /// Generation of the most recent replacement stream on the installed
    /// connection. A write that completes on an older stream after the
    /// replacement is stranded the moment it is noted.
    var repairedControlStreamGeneration: UInt64 = 0
    var controlStreamRepairInFlight = false
    /// Replacements on the installed connection not yet verified by an answer.
    var unverifiedControlStreamRepairs = 0
    var readerTask: Task<Void, Never>?
    /// Watches the complete native connection, separately from the control
    /// lane reader. IROH can close the shared QUIC session without making a
    /// blocked application-lane read return, so relying on `readLoop` alone
    /// leaves event listeners attached to a dead generation.
    var transportClosureTask: Task<Void, Never>?
    var independentEventPreparation: IndependentEventPreparation?
    var independentEventReader: IndependentEventReader?
    /// Subscription stream IDs that already made their one optional-lane
    /// negotiation attempt during this control-session generation.
    var independentEventSubscriptionStreamIDs: Set<String> = []
    var pending: [String: PendingContinuation] = [:]
    var pipelinedPending: [String: PipelinedRequestSettlement] = [:]
    var requestTimeoutTasks: [String: Task<Void, Never>] = [:]
    var queuedWriteIDs: [String: UUID] = [:]
    var cancelledQueuedWriteIDs: Set<UUID> = []
    // `internal` so cancellation tests can observe the writer-queue gate via
    // `@testable import` without adding a production debug hook.
    var queuedRequestIDs: Set<String> { Set(queuedWriteIDs.keys) }
    var writeResolutionWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    // `internal` so recovery tests can assert waiter cleanup via `@testable import`.
    var writeResolutionWaiterCount: Int { writeResolutionWaiters.count }
    var listeners: [UUID: EventListener] = [:]
    var isTearingDown: Bool = false
    var tearDownWaiters: [CheckedContinuation<Void, Never>] = []
    var writeQueue: AsyncStream<PendingWrite>.Continuation?
    var writerTask: Task<Void, Never>?
    var activeWrite: ActiveWrite?
    /// Each installed close has independent lifetime and is also retained by
    /// the shared registry, so session deallocation cannot strand a queued
    /// transport or its route lease.
    var transportCloseTasks: [UUID: Task<Void, Never>] = [:]
    var abandonedConnectionCleanupTasks: [UUID: Task<Void, Never>] = [:]

    init(
        connectAttemptKey: MobileRPCConnectAttemptKey? = nil,
        connectAttemptRegistry: MobileRPCConnectAttemptRegistry = MobileRPCConnectAttemptRegistry(),
        abandonedConnectCleanupTimeoutNanoseconds: UInt64 = 1_000_000_000,
        lateAbandonedConnectCloseTimeoutNanoseconds: UInt64 = 5_000_000_000,
        cancelledWriteCompletionGraceNanoseconds: UInt64 =
            MobileCoreRPCSession.defaultCancelledWriteCompletionGraceNanoseconds,
        makeTransport: @escaping TransportFactory,
        makeIndependentEventByteStream: IndependentEventByteStreamFactory? = nil,
        didReceiveConnectedCandidate: ConnectedCandidateHook? = nil,
        diagnosticTransport: DiagnosticTransportKind? = nil,
        transportConnectObserver: TransportConnectObserver? = nil,
        initialTransportSessionPurpose: CmxTransportSessionPurpose? = nil,
        tearDownRegistrationHook: TearDownRegistrationHook? = nil
    ) {
        self.connectAttemptKey = connectAttemptKey
        self.connectAttemptRegistry = connectAttemptRegistry
        self.abandonedConnectCleanupTimeoutNanoseconds = abandonedConnectCleanupTimeoutNanoseconds
        self.lateAbandonedConnectCloseTimeoutNanoseconds = lateAbandonedConnectCloseTimeoutNanoseconds
        self.cancelledWriteCompletionGraceNanoseconds =
            cancelledWriteCompletionGraceNanoseconds
        self.makeTransport = makeTransport
        self.makeIndependentEventByteStream = makeIndependentEventByteStream
        self.didReceiveConnectedCandidate = didReceiveConnectedCandidate
        self.diagnosticTransport = diagnosticTransport
        self.transportConnectObserver = transportConnectObserver
        self.transportSessionPurpose = initialTransportSessionPurpose
        self.tearDownRegistrationHook = tearDownRegistrationHook
    }

    deinit {
        let connecting = connectionTask
        if let connecting,
           let attemptID = connecting.diagnosticAttemptID,
           let diagnosticTransport,
           let transportConnectObserver {
            transportConnectObserver(.cancelled(
                attemptID: attemptID,
                transport: diagnosticTransport,
                reason: .sessionDeinitialized,
                elapsedMilliseconds: Self.elapsedMilliseconds(
                    since: connecting.diagnosticStartedAt ?? ContinuousClock.now
                )
            ))
        }
        connecting?.task.cancel()
        let installedTransport = transport
        let installedLease = installedConnectLease
        let registry = connectAttemptRegistry
        if let connecting {
            Task.detached {
                await registry.handOffPhysicalCleanup(
                    lease: connecting.lease
                ) {
                    do {
                        let candidate = try await connecting.task.value
                        if let cancellationCloseTask =
                            await connecting.cancellationClose.task() {
                            await cancellationCloseTask.value
                        }
                        await candidate.close()
                    } catch {
                        if let cancellationCloseTask =
                            await connecting.cancellationClose.task() {
                            await cancellationCloseTask.value
                        }
                    }
                }
            }
        }
        if installedTransport != nil || installedLease != nil {
            Task.detached {
                await registry.handOffPhysicalCleanup(
                    lease: installedLease
                ) {
                    await installedTransport?.close()
                }
            }
        }
        readerTask?.cancel()
        transportClosureTask?.cancel()
        independentEventPreparation?.task.cancel()
        independentEventReader?.task.cancel()
        activeWrite?.task.cancel()
        activeWrite?.cancelledRequestResolutionTask?.cancel()
        writerTask?.cancel()
        writeQueue?.finish()
    }

    func send(payload: Data, requestID: String, deadlineUptimeNanoseconds: UInt64) async throws -> Data {
        try await waitForCancelledActiveWriteResolution(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(until: deadlineUptimeNanoseconds)

        let settlement: PendingRequestSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard pending[requestID] == nil,
                      pipelinedPending[requestID] == nil,
                      queuedWriteIDs[requestID] == nil else {
                    continuation.resume(returning: .response(.failure(.invalidResponse)))
                    return
                }
                let queuedWriteID = UUID()
                pending[requestID] = continuation
                armResponseTimeout(
                    requestID: requestID,
                    timeoutNanoseconds: responseTimeoutNanoseconds
                )
                guard let queue = writeQueue else {
                    requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                    pending.removeValue(forKey: requestID)
                    continuation.resume(returning: .response(.failure(.connectionClosed)))
                    return
                }
                queuedWriteIDs[requestID] = queuedWriteID
                _ = queue.yield(PendingWrite(id: queuedWriteID, requestID: requestID, frame: frame))
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(requestID: requestID)
            }
        }
        return try Self.resolvePendingSettlement(settlement, isCancelled: Task.isCancelled)
    }

    func beginSend(
        payload: Data,
        requestID: String,
        deadlineUptimeNanoseconds: UInt64
    ) async throws {
        // Same demand gate as send(): new work must not queue behind a
        // cancelled unresolved write, or it hangs until its own deadline
        // behind a transport its timeout may have to condemn.
        try await waitForCancelledActiveWriteResolution(
            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds
        )
        _ = try await ensureConnected(
            timeoutNanoseconds: try taskTimeout.remainingNanoseconds(
                until: deadlineUptimeNanoseconds
            )
        )
        let frame = try MobileSyncFrameCodec.encodeFrame(payload)
        let responseTimeoutNanoseconds = try taskTimeout.remainingNanoseconds(
            until: deadlineUptimeNanoseconds
        )
        guard pending[requestID] == nil,
              pipelinedPending[requestID] == nil,
              queuedWriteIDs[requestID] == nil else {
            throw MobileShellConnectionError.invalidResponse
        }
        guard let queue = writeQueue else {
            throw MobileShellConnectionError.connectionClosed
        }
        let queuedWriteID = UUID()
        pipelinedPending[requestID] = .pending
        armResponseTimeout(
            requestID: requestID,
            timeoutNanoseconds: responseTimeoutNanoseconds
        )
        queuedWriteIDs[requestID] = queuedWriteID
        _ = queue.yield(PendingWrite(
            id: queuedWriteID,
            requestID: requestID,
            frame: frame
        ))
    }

    func awaitResponse(requestID: String) async throws -> Data {
        let settlement: PendingRequestSettlement = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                switch pipelinedPending[requestID] {
                case .pending:
                    pipelinedPending[requestID] = .awaiting(continuation)
                case let .settled(settlement):
                    pipelinedPending.removeValue(forKey: requestID)
                    continuation.resume(returning: settlement)
                case .awaiting, nil:
                    continuation.resume(
                        returning: .response(.failure(.invalidResponse))
                    )
                }
            }
        } onCancel: {
            Task {
                await self.cancelPendingRequest(requestID: requestID)
            }
        }
        return try Self.resolvePendingSettlement(
            settlement,
            isCancelled: Task.isCancelled
        )
    }

    func addEventListener(topics: Set<String>) -> EventSubscription {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MobileEventEnvelope>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        listeners[id] = EventListener(topics: topics, continuation: continuation)
        continuation.onTermination = { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.removeListener(id: id) }
        }
        return EventSubscription(id: id, stream: stream)
    }

    func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    /// Snapshot whether the complete native transport has closed. A control
    /// request can stall while an Iroh session and its terminal lane continue
    /// to carry traffic, so replacement logic must consult this before
    /// discarding a still-live session.
    public func isTransportClosed() async -> Bool? {
        guard let transport = transport as? any CmxByteTransportLivenessObserving else {
            return nil
        }
        return await transport.isTransportClosed()
    }

    func updateTransportSessionPurpose(
        _ purpose: CmxTransportSessionPurpose
    ) async {
        transportSessionPurpose = purpose
        guard let updating =
            transport as? any CmxByteTransportSessionPurposeUpdating else {
            return
        }
        let connectionID = installedConnectionID
        var appliedPurpose: CmxTransportSessionPurpose?
        while installedConnectionID == connectionID,
              transport != nil,
              let currentPurpose = transportSessionPurpose,
              currentPurpose != appliedPurpose {
            await updating.updateSessionPurpose(currentPurpose)
            appliedPurpose = currentPurpose
        }
    }
}
