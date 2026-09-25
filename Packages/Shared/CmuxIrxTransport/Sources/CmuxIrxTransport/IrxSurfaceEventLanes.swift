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
/// - At most ``Configuration/maximumLaneCount`` lanes stay open; opening one
///   more finishes the least recently written lane.
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
            maximumLaneCount: Int = 16,
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
    }

    /// Stream reset codes, visible to the phone as the lane's stop reason.
    public enum ResetCode {
        public static let superseded: UInt64 = 0
        public static let writeFailed: UInt64 = 6
        public static let stalled: UInt64 = 7
    }

    public typealias Opener = @Sendable (IrxLaneDescriptor) async throws -> any IrxEventLaneWriting

    private struct Lane {
        let token: UInt64
        let generation: UInt64
        let writer: any IrxEventLaneWriting
        var priority: Int32
        var lastUse: UInt64
        var priorityUpdate: Task<Void, Never>?
    }

    public nonisolated let configuration: Configuration
    private let open: Opener
    private let journal: IrxJournal?
    private var lanes: [String: Lane] = [:]
    private var focusedSurfaceID: String?
    private var isEnabled = true
    private var nextToken: UInt64 = 0
    private var useTick: UInt64 = 0

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
        let surfaceID = IrxSurfaceEventLaneProtocol.normalizedSurfaceID(rawSurfaceID)
        let lane = try await openedLane(surfaceID: surfaceID, generation: generation)
        useTick &+= 1
        lanes[surfaceID]?.lastUse = useTick
        let writer = lane.writer
        let result: IrxDeadlineResult<Bool>
        do {
            result = try await withIrxDeadlineResult(configuration.stallDeadline) {
                try await writer.write(data)
                return true
            }
        } catch {
            retire(surfaceID: surfaceID, token: lane.token, errorCode: ResetCode.writeFailed)
            throw error
        }
        if case .timeout = result {
            retire(surfaceID: surfaceID, token: lane.token, errorCode: ResetCode.stalled)
            journal?.record("host-surface-lanes", "write-stalled", ["surface": surfaceID])
            throw LaneError.writeStalled
        }
    }

    /// Marks the surface the user is interacting with; its lane is scheduled
    /// ahead of every other surface and the bulk events lane.
    public func noteFocused(surfaceID rawSurfaceID: String) {
        let surfaceID = IrxSurfaceEventLaneProtocol.normalizedSurfaceID(rawSurfaceID)
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
        if !enabled { finishAll() }
    }

    /// Finishes one surface's lane, if the lane is still `generation`'s.
    public func close(surfaceID rawSurfaceID: String, generation: UInt64? = nil) {
        let surfaceID = IrxSurfaceEventLaneProtocol.normalizedSurfaceID(rawSurfaceID)
        guard let lane = lanes[surfaceID],
              generation == nil || lane.generation == generation else { return }
        lanes.removeValue(forKey: surfaceID)
        let writer = lane.writer
        Task { await writer.finish() }
    }

    /// Finishes every lane and permanently refuses new ones.
    public func closeAll() {
        isEnabled = false
        finishAll()
    }

    public func openSurfaceIDs() -> Set<String> { Set(lanes.keys) }

    public func priority(surfaceID rawSurfaceID: String) -> Int32? {
        lanes[IrxSurfaceEventLaneProtocol.normalizedSurfaceID(rawSurfaceID)]?.priority
    }

    private func openedLane(surfaceID: String, generation: UInt64) async throws -> Lane {
        if let lane = lanes[surfaceID] {
            if lane.generation == generation { return lane }
            // A newer generation means frames on the old stream may be lost;
            // never mix the chain across the two streams.
            lanes.removeValue(forKey: surfaceID)
            let writer = lane.writer
            Task { await writer.finish() }
        }
        evictLeastRecentlyUsedLaneIfFull()
        let descriptor = IrxSurfaceEventLaneProtocol.descriptor(surfaceID: surfaceID)
        let opener = open
        // Opening waits for stream credit. The native open ignores task
        // cancellation, so a late stream is released instead of leaked.
        let openTask = Task { try await opener(descriptor) }
        let result = try await withIrxDeadlineResult(configuration.openDeadline) {
            try await openTask.value
        }
        guard case .operation(let opened?) = result else {
            Task {
                if let late = try? await openTask.value {
                    await late.reset(errorCode: ResetCode.superseded)
                }
            }
            journal?.record("host-surface-lanes", "open-timed-out", ["surface": surfaceID])
            throw LaneError.openTimedOut
        }
        guard isEnabled else {
            await opened.reset(errorCode: ResetCode.superseded)
            throw LaneError.disabled
        }
        if let raced = lanes[surfaceID], raced.generation == generation {
            // A concurrent send for the same generation won the open.
            await opened.reset(errorCode: ResetCode.superseded)
            return raced
        }
        nextToken &+= 1
        let priority = priorityFor(surfaceID: surfaceID)
        try? await opened.setPriority(priority)
        let lane = Lane(
            token: nextToken,
            generation: generation,
            writer: opened,
            priority: priority,
            lastUse: useTick
        )
        if let replaced = lanes[surfaceID] {
            let writer = replaced.writer
            Task { await writer.finish() }
        }
        lanes[surfaceID] = lane
        journal?.record(
            "host-surface-lanes", "opened",
            ["surface": surfaceID, "priority": String(priority), "open": String(lanes.count)]
        )
        return lane
    }

    private func evictLeastRecentlyUsedLaneIfFull() {
        while lanes.count >= configuration.maximumLaneCount,
              let victim = lanes.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            lanes.removeValue(forKey: victim.key)
            let writer = victim.value.writer
            Task { await writer.finish() }
            journal?.record("host-surface-lanes", "evicted", ["surface": victim.key])
        }
    }

    private func retire(surfaceID: String, token: UInt64, errorCode: UInt64) {
        guard let lane = lanes[surfaceID], lane.token == token else { return }
        lanes.removeValue(forKey: surfaceID)
        let writer = lane.writer
        // Reset crosses a cancellation-insensitive native bridge; never make
        // the caller's recovery wait on it.
        Task { await writer.reset(errorCode: errorCode) }
    }

    private func finishAll() {
        let writers = lanes.values.map(\.writer)
        lanes.removeAll()
        for writer in writers {
            Task { await writer.finish() }
        }
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
            try? await writer.setPriority(priority)
        }
    }
}
