public import Foundation

/// Server-side owner of one uni QUIC stream per terminal surface.
///
/// QUIC delivers each stream in order, so a burst or replay for one terminal
/// on a shared stream head-of-line-blocks every other terminal's output,
/// including the echo of a key typed on another terminal. Each surface here
/// gets its own stream: a stalled or failed stream affects only its surface.
///
/// Contract:
/// - A lane opens lazily on the first ``send(_:surfaceID:generation:)`` and is
///   keyed by `(surface, generation)`. A new generation finishes the previous
///   stream and opens a fresh one, so a caller that bumps the generation after
///   a failure never writes onto a stream whose earlier frames may be lost.
/// - A send that throws has already retired its lane (reset); the next send
///   reopens. Recovery is per surface and never touches the QUIC connection.
/// - A write that makes no progress within the stall deadline retires the lane
///   and throws ``LaneError/writeStalled``. The native reset may itself wait
///   for the stuck write (iroh-ffi serializes stream calls), so recovery never
///   waits for it: the next send opens a fresh stream while the reset runs
///   in the background.
/// - At most ``Configuration/maximumLaneCount`` lanes are open or opening at
///   once. A stream waiting for the peer's credit reserves a slot, so
///   concurrent opens cannot overshoot the negotiated limit. A send over the
///   limit is refused instead of evicting another surface's lane.
/// - ``release(surfaceID:belowGeneration:)`` resets a surface's lane, drops
///   its unsent backlog, and rejects stale sends from before the release.
/// - The focused surface's stream runs at ``Configuration/focusedPriority``;
///   every other surface shares ``Configuration/backgroundPriority`` with the
///   bulk events lane, so interactive echo is scheduled first. Priority
///   changes never wait on a lane's in-flight write, so noting focus from the
///   input path cannot delay input.
public actor IrxSurfaceEventLanes {
    public struct Configuration: Sendable {
        public var maximumLaneCount: Int
        public var focusedPriority: Int32
        public var backgroundPriority: Int32
        public var openDeadline: Duration
        public var stallDeadline: Duration

        public init(
            maximumLaneCount: Int = 4,
            focusedPriority: Int32 = 100,
            backgroundPriority: Int32 = 50,
            openDeadline: Duration = .seconds(5),
            stallDeadline: Duration = .seconds(15)
        ) {
            self.maximumLaneCount = max(1, maximumLaneCount)
            self.focusedPriority = focusedPriority
            self.backgroundPriority = backgroundPriority
            self.openDeadline = openDeadline
            self.stallDeadline = stallDeadline
        }
    }

    public enum LaneError: Error, Equatable, Sendable {
        case disabled
        case openTimedOut
        case writeStalled
        case laneLimit
        case released
    }

    // Stream reset codes, visible to the phone as the lane's stop reason.
    public static let supersededResetCode: UInt64 = 0
    public static let writeFailedResetCode: UInt64 = 6
    public static let stalledResetCode: UInt64 = 7
    public static let releasedResetCode: UInt64 = 8

    public typealias Opener = @Sendable (IrxLaneDescriptor) async throws -> any IrxEventLaneWriting

    private struct Lane {
        let token: UInt64
        let generation: UInt64
        let writer: any IrxEventLaneWriting
        var priority: Int32
        var priorityUpdate: Task<Void, Never>?
    }

    private struct BackgroundOperation {
        let task: Task<Void, Never>
        let cancelOnShutdown: Bool
    }

    public nonisolated let configuration: Configuration
    private let open: Opener
    private let journal: IrxJournal?
    private var lanes: [String: Lane] = [:]
    private var focusedSurfaceID: String?
    private var isEnabled = true
    /// Changes whenever surface-lane delivery is disabled or re-enabled. An
    /// open that started before a fallback must never install its native
    /// stream after the fallback, even if delivery is enabled again before the
    /// cancellation-insensitive native open returns.
    private var enableEpoch: UInt64 = 0
    private var nextToken: UInt64 = 0
    private var pendingOpenCount = 0
    /// Native finish/reset calls keep a uni stream alive until they return.
    /// Count those calls so a blocked cleanup cannot let later focus changes
    /// oversubscribe the peer's stream credit.
    private var retiringLaneCount = 0
    private var nextBackgroundOperationID: UInt64 = 0
    private var backgroundOperations: [UInt64: BackgroundOperation] = [:]
    /// Lowest generation a released surface may send from now on.
    private var minimumGenerationBySurfaceID: [String: UInt64] = [:]

    public init(
        configuration: Configuration = Configuration(),
        journal: IrxJournal? = nil,
        open: @escaping Opener
    ) {
        self.configuration = configuration
        self.journal = journal
        self.open = open
    }

    /// Writes one complete frame onto the surface's lane.
    public func send(_ data: Data, surfaceID rawSurfaceID: String, generation: UInt64) async throws {
        guard isEnabled else { throw LaneError.disabled }
        let surfaceID = IrxSurfaceEventLaneProtocol().normalizedSurfaceID(rawSurfaceID)
        let lane = try await openedLane(surfaceID: surfaceID, generation: generation)
        let writer = lane.writer
        let result: IrxDeadlineResult<Bool>
        do {
            result = try await withIrxDeadlineResult(configuration.stallDeadline) {
                try await writer.write(data)
                return true
            }
        } catch {
            retire(surfaceID: surfaceID, token: lane.token, errorCode: Self.writeFailedResetCode)
            throw error
        }
        if case .timeout = result {
            retire(surfaceID: surfaceID, token: lane.token, errorCode: Self.stalledResetCode)
            journal?.record("host-surface-lanes", "write-stalled", ["surface": surfaceID])
            throw LaneError.writeStalled
        }
    }

    /// Marks the surface the user is interacting with; its lane is scheduled
    /// ahead of every other surface and the bulk events lane.
    public func noteFocused(surfaceID rawSurfaceID: String) {
        let surfaceID = IrxSurfaceEventLaneProtocol().normalizedSurfaceID(rawSurfaceID)
        guard !surfaceID.isEmpty, focusedSurfaceID != surfaceID else { return }
        let previous = focusedSurfaceID
        focusedSurfaceID = surfaceID
        if let previous { applyPriority(surfaceID: previous) }
        applyPriority(surfaceID: surfaceID)
    }

    /// Disabling finishes every lane and refuses new ones until re-enabled.
    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        enableEpoch &+= 1
        if !enabled { finishAll(cancelBackgroundOperations: false) }
    }

    /// Finishes one surface's lane, if the lane is still `generation`'s.
    public func close(surfaceID rawSurfaceID: String, generation: UInt64? = nil) {
        let surfaceID = IrxSurfaceEventLaneProtocol().normalizedSurfaceID(rawSurfaceID)
        guard let lane = lanes[surfaceID],
              generation == nil || lane.generation == generation else { return }
        lanes.removeValue(forKey: surfaceID)
        lane.priorityUpdate?.cancel()
        let writer = lane.writer
        startRetiringOperation { await writer.finish() }
    }

    /// Resets a surface's lane and refuses sends from generations before the
    /// caller's newly assigned generation. Reset is intentionally detached:
    /// native stream reset can wait behind an in-flight write, while the
    /// connection's focused-lane transition must remain bounded.
    public func release(surfaceID rawSurfaceID: String, belowGeneration generation: UInt64) {
        let surfaceID = IrxSurfaceEventLaneProtocol().normalizedSurfaceID(rawSurfaceID)
        minimumGenerationBySurfaceID[surfaceID] = max(
            generation,
            minimumGenerationBySurfaceID[surfaceID] ?? 0
        )
        guard let lane = lanes[surfaceID], lane.generation < generation else { return }
        lanes.removeValue(forKey: surfaceID)
        lane.priorityUpdate?.cancel()
        let writer = lane.writer
        journal?.record("host-surface-lanes", "released", ["surface": surfaceID])
        startRetiringOperation { await writer.reset(errorCode: Self.releasedResetCode) }
    }

    /// Finishes every lane and permanently refuses new ones.
    public func closeAll() {
        isEnabled = false
        enableEpoch &+= 1
        finishAll(cancelBackgroundOperations: true)
    }

    public func openSurfaceIDs() -> Set<String> { Set(lanes.keys) }

    public func priority(surfaceID rawSurfaceID: String) -> Int32? {
        lanes[IrxSurfaceEventLaneProtocol().normalizedSurfaceID(rawSurfaceID)]?.priority
    }

    private func openedLane(surfaceID: String, generation: UInt64) async throws -> Lane {
        guard generation >= minimumGenerationBySurfaceID[surfaceID, default: 0] else {
            throw LaneError.released
        }
        // Record the newest requested generation before the native open
        // suspends. An older open that completes later must not replace it.
        minimumGenerationBySurfaceID[surfaceID] = generation
        if let lane = lanes[surfaceID] {
            if lane.generation == generation { return lane }
            // A newer generation means frames on the old stream may be lost;
            // never mix the chain across the two streams.
            lanes.removeValue(forKey: surfaceID)
            lane.priorityUpdate?.cancel()
            let writer = lane.writer
            startRetiringOperation { await writer.finish() }
        }
        guard lanes.count + pendingOpenCount + retiringLaneCount < configuration.maximumLaneCount else {
            journal?.record(
                "host-surface-lanes", "open-refused",
                [
                    "surface": surfaceID,
                    "open": String(lanes.count),
                    "pending": String(pendingOpenCount),
                    "retiring": String(retiringLaneCount),
                ]
            )
            throw LaneError.laneLimit
        }
        let descriptor = IrxSurfaceEventLaneProtocol().descriptor(surfaceID: surfaceID)
        let opener = open
        let openEpoch = enableEpoch
        // Opening waits for stream credit. Reserve the slot across the await;
        // otherwise concurrent sends all pass the limit check before any open
        // completes. The native open ignores task cancellation, so a late
        // stream is released instead of leaked.
        pendingOpenCount += 1
        let openTask = Task { try await opener(descriptor) }
        let result: IrxDeadlineResult<any IrxEventLaneWriting>
        do {
            result = try await withIrxDeadlineResult(configuration.openDeadline) {
                try await openTask.value
            }
        } catch {
            pendingOpenCount -= 1
            throw error
        }
        guard case .operation(let opened?) = result else {
            // The native open ignores cancellation and may still consume the
            // peer's stream credit after our deadline. Keep the slot reserved
            // until that late stream returns and is reset; otherwise each
            // timeout can launch another native open and recreate credit
            // exhaustion.
            startBackgroundOperation(cancelOnShutdown: false) { [weak self] in
                if let late = try? await openTask.value {
                    await late.reset(errorCode: Self.supersededResetCode)
                }
                await self?.pendingOpenFinished()
            }
            journal?.record("host-surface-lanes", "open-timed-out", ["surface": surfaceID])
            throw LaneError.openTimedOut
        }
        guard isEnabled, enableEpoch == openEpoch else {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.supersededResetCode) }
            throw LaneError.disabled
        }
        guard generation >= minimumGenerationBySurfaceID[surfaceID, default: 0] else {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.releasedResetCode) }
            throw LaneError.released
        }
        if let raced = lanes[surfaceID], raced.generation == generation {
            // A concurrent send for the same generation won the open.
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.supersededResetCode) }
            return raced
        }
        let priority = priorityFor(surfaceID: surfaceID)
        try? await opened.setPriority(priority)
        // Setting native priority can suspend behind a stream write. The
        // release/focus path may advance the generation while it waits, so
        // revalidate every admission condition before committing the lane.
        guard isEnabled, enableEpoch == openEpoch else {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.supersededResetCode) }
            throw LaneError.disabled
        }
        guard generation >= minimumGenerationBySurfaceID[surfaceID, default: 0] else {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.releasedResetCode) }
            throw LaneError.released
        }
        if let raced = lanes[surfaceID], raced.generation == generation {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.supersededResetCode) }
            return raced
        }
        // The current native stream is still part of pendingOpenCount. It may
        // commit only when all installed, pending, and retiring streams fit.
        guard lanes.count + pendingOpenCount + retiringLaneCount <= configuration.maximumLaneCount else {
            pendingOpenCount -= 1
            startRetiringOperation { await opened.reset(errorCode: Self.supersededResetCode) }
            throw LaneError.laneLimit
        }
        nextToken &+= 1
        let lane = Lane(
            token: nextToken,
            generation: generation,
            writer: opened,
            priority: priority
        )
        if let replaced = lanes[surfaceID] {
            replaced.priorityUpdate?.cancel()
            let writer = replaced.writer
            startRetiringOperation { await writer.finish() }
        }
        lanes[surfaceID] = lane
        pendingOpenCount -= 1
        journal?.record(
            "host-surface-lanes", "opened",
            ["surface": surfaceID, "priority": String(priority), "open": String(lanes.count)]
        )
        return lane
    }

    private func pendingOpenFinished() {
        pendingOpenCount = max(0, pendingOpenCount - 1)
    }

    private func retire(surfaceID: String, token: UInt64, errorCode: UInt64) {
        guard let lane = lanes[surfaceID], lane.token == token else { return }
        lanes.removeValue(forKey: surfaceID)
        lane.priorityUpdate?.cancel()
        let writer = lane.writer
        // Reset crosses a cancellation-insensitive native bridge; never make
        // the caller's recovery wait on it.
        startRetiringOperation { await writer.reset(errorCode: errorCode) }
    }

    private func finishAll(cancelBackgroundOperations: Bool) {
        let writers = lanes.values.map(\.writer)
        for lane in lanes.values { lane.priorityUpdate?.cancel() }
        lanes.removeAll()
        if cancelBackgroundOperations {
            for operation in backgroundOperations.values where operation.cancelOnShutdown {
                operation.task.cancel()
            }
        }
        for writer in writers {
            startRetiringOperation { await writer.finish() }
        }
    }

    private func startRetiringOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) {
        retiringLaneCount += 1
        startBackgroundOperation(cancelOnShutdown: false) { [weak self] in
            await operation()
            await self?.retiringOperationFinished()
        }
    }

    private func retiringOperationFinished() {
        retiringLaneCount = max(0, retiringLaneCount - 1)
    }

    private func startBackgroundOperation(
        cancelOnShutdown: Bool = true,
        operation: @escaping @Sendable () async -> Void
    ) {
        nextBackgroundOperationID &+= 1
        let operationID = nextBackgroundOperationID
        let (start, startContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let task = Task { [weak self] in
            var iterator = start.makeAsyncIterator()
            _ = await iterator.next()
            if cancelOnShutdown, Task.isCancelled {
                await self?.finishBackgroundOperation(operationID)
                return
            }
            await operation()
            await self?.finishBackgroundOperation(operationID)
        }
        backgroundOperations[operationID] = BackgroundOperation(
            task: task,
            cancelOnShutdown: cancelOnShutdown
        )
        startContinuation.yield(())
        startContinuation.finish()
    }

    private func finishBackgroundOperation(_ operationID: UInt64) {
        backgroundOperations.removeValue(forKey: operationID)
    }

    private func priorityFor(surfaceID: String) -> Int32 {
        surfaceID == focusedSurfaceID
            ? configuration.focusedPriority
            : configuration.backgroundPriority
    }

    private func applyPriority(surfaceID: String) {
        guard var lane = lanes[surfaceID] else { return }
        let priority = priorityFor(surfaceID: surfaceID)
        guard lane.priority != priority else { return }
        lane.priority = priority
        lanes[surfaceID] = lane
        // The native call waits for the lane's in-flight write; apply it
        // off the caller's path. Updates for one lane are serialized.
        let writer = lane.writer
        let previous = lane.priorityUpdate
        lanes[surfaceID]?.priorityUpdate = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await writer.setPriority(priority)
        }
    }
}
