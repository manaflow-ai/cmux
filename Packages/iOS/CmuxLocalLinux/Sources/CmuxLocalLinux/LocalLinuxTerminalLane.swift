public import CmuxMobileRPC
public import Foundation

/// The concurrency-safe surface that a local Linux terminal lane needs from
/// its pty session.
///
/// `LocalLinuxSession` conforms to this protocol in the iSH build. Keeping the
/// lane on this seam lets package tests exercise framing and lifecycle
/// behaviour without loading the arm64-only iSH binary target.
public nonisolated protocol LocalLinuxOutputSource: AnyObject, Sendable {
    /// A single-consumer byte stream owned by the source. The scrollback ring
    /// installs one consumer and fans out bounded subscriptions to lanes.
    var output: AsyncStream<Data> { get }

    /// Attempts one exact input operation. The returned count is the number of
    /// bytes accepted by the pty; a short count is surfaced by the lane rather
    /// than silently dropping user input.
    func send(_ data: Data) async throws -> Int

    /// Terminates the pty and finishes `output`. Implementations must be
    /// idempotent because explicit termination races stream teardown by design.
    func hangup() async
}

extension LocalLinuxSession: LocalLinuxOutputSource {}

/// Errors raised while driving a local Linux lane.
public enum LocalLinuxLaneError: Error, Equatable, Sendable {
    case closed
    case emptyInput
    case inputTooLarge
    case inputPartiallyAccepted(accepted: Int, expected: Int)
    case invalidInputCount(Int)
    case cursorGap(requested: UInt64, retainedBase: UInt64, current: UInt64)
    case cursorAhead(requested: UInt64, current: UInt64)
    case sourceMismatch
    case concurrentReceive
}

/// One local iSH pty exposed through the same sequence-aware lane contract as
/// a paired Mac terminal.
///
/// A lane is an attachment, not the owner of the shell process. `close()`
/// detaches the lane so the coordinator can reopen after a transient stream
/// failure. Call `terminate()` when the local terminal itself is deleted.
public actor LocalLinuxTerminalLane: MobileTerminalLaneConnection {
    /// Maximum UTF-8 input accepted in one operation, matching the remote lane.
    public static let maximumInputByteCount = 16 * 1_024

    /// Maximum output payload in one frame. Large callback writes are split so
    /// one kernel write cannot monopolise the lane or allocate an unbounded
    /// frame in the consumer.
    public static let maximumOutputByteCount = 256 * 1_024

    /// Retained replay budget per terminal.
    public static let retainedByteLimit = 512 * 1_024

    private let source: any LocalLinuxOutputSource
    private let ring: LocalLinuxScrollbackRing
    private let requestedCursor: UInt64?
    private var subscriptionID: UUID?
    private var updates: AsyncStream<MobileTerminalLaneOutputFrame>?
    private var receiveInFlight = false
    private var closed = false

    /// Creates a lane over any local pty source.
    public init(
        source: any LocalLinuxOutputSource,
        ring: LocalLinuxScrollbackRing,
        cursor: UInt64? = nil
    ) {
        self.source = source
        self.ring = ring
        self.requestedCursor = cursor
    }

    /// Convenience initializer for the embedded iSH pty.
    public init(
        session: LocalLinuxSession,
        ring: LocalLinuxScrollbackRing,
        cursor: UInt64? = nil
    ) {
        self.init(source: session, ring: ring, cursor: cursor)
    }

    /// Returns the replay frame first, then bounded live output frames.
    public func receiveOutput() async throws -> MobileTerminalLaneOutputFrame? {
        guard !closed else { return nil }
        try Task.checkCancellation()
        guard !receiveInFlight else {
            throw LocalLinuxLaneError.concurrentReceive
        }
        receiveInFlight = true
        defer { receiveInFlight = false }

        if subscriptionID == nil {
            let subscription = try await ring.subscribe(
                source: source,
                cursor: requestedCursor,
                maximumPendingFrames: 64,
                maximumFrameByteCount: Self.maximumOutputByteCount
            )

            // A cancelled open must not leave a subscriber behind. The ring
            // starts its source pump as part of `subscribe`, so cleanup is
            // required even when cancellation wins before the replay returns.
            do {
                try Task.checkCancellation()
            } catch {
                await ring.unsubscribe(subscription.id)
                throw error
            }

            // `close()` can run while the actor is suspended in `subscribe`.
            // Do not install a subscription after teardown; otherwise its
            // continuation would keep the source and pump alive.
            guard !closed else {
                await ring.unsubscribe(subscription.id)
                return nil
            }

            subscriptionID = subscription.id
            updates = subscription.updates
            return subscription.replay
        }

        guard let updates else { return nil }
        // Keep the mutable iterator local to the nonisolated `next()` call.
        // Storing it in an actor and passing it across an await triggers the
        // Swift 6 sending-risks diagnostic. AsyncStream keeps its cursor in
        // shared storage, so a fresh iterator continues this lane's queue.
        var iterator = updates.makeAsyncIterator()
        let next = await iterator.next()

        do {
            try Task.checkCancellation()
        } catch {
            if let subscriptionID {
                self.subscriptionID = nil
                self.updates = nil
                await ring.unsubscribe(subscriptionID)
            }
            throw error
        }

        // `next()` suspends. Teardown may have finished the stream while it
        // was suspended, so check the state before accepting the result.
        guard !closed else { return nil }

        guard let frame = next else {
            if let subscriptionID {
                self.subscriptionID = nil
                self.updates = nil
                await ring.unsubscribe(subscriptionID)
            }
            return nil
        }
        return frame
    }

    /// Sends one complete UTF-8 terminal-input operation.
    public func sendInput(_ input: String) async throws {
        guard !closed else { throw LocalLinuxLaneError.closed }
        try Task.checkCancellation()
        let bytes = Data(input.utf8)
        guard !bytes.isEmpty else { throw LocalLinuxLaneError.emptyInput }
        guard bytes.count <= Self.maximumInputByteCount else {
            throw LocalLinuxLaneError.inputTooLarge
        }

        let accepted = try await source.send(bytes)
        try Task.checkCancellation()
        guard !closed else { throw LocalLinuxLaneError.closed }
        guard accepted >= 0, accepted <= bytes.count else {
            throw LocalLinuxLaneError.invalidInputCount(accepted)
        }
        guard accepted == bytes.count else {
            throw LocalLinuxLaneError.inputPartiallyAccepted(
                accepted: accepted,
                expected: bytes.count
            )
        }
    }

    /// Detaches this lane while retaining the local shell and its output ring.
    /// Idempotent and safe to call while `receiveOutput()` is waiting.
    public func close() async {
        guard !closed else { return }
        closed = true
        updates = nil

        if let subscriptionID {
            self.subscriptionID = nil
            await ring.unsubscribe(subscriptionID)
        }
    }

    /// Terminates the local shell after detaching this lane. The local store
    /// should call this when the terminal is explicitly closed or deleted.
    public func terminate() async {
        await close()
        await source.hangup()
    }
}

/// A bounded, sequence-aware output history and fan-out hub for one local pty.
///
/// The hub is the sole consumer of `LocalLinuxOutputSource.output`. It appends
/// every callback write before yielding to a bounded subscriber stream. This
/// keeps replay continuity across lane attachments and turns slow-consumer
/// pressure into a clean stream finish, which the coordinator can recover by
/// reopening from its cursor.
public actor LocalLinuxScrollbackRing {
    public struct Snapshot: Sendable {
        /// The selected start sequence used by the legacy snapshot API.
        public let baseSequence: UInt64
        /// The absolute floor still retained by the ring. This can be lower
        /// than `baseSequence` when a cursor selects a suffix.
        public let retainedBaseSequence: UInt64
        public let currentSequence: UInt64
        public let bytes: Data

        public init(
            baseSequence: UInt64,
            retainedBaseSequence: UInt64? = nil,
            currentSequence: UInt64,
            bytes: Data
        ) {
            self.baseSequence = baseSequence
            self.retainedBaseSequence = retainedBaseSequence ?? baseSequence
            self.currentSequence = currentSequence
            self.bytes = bytes
        }
    }

    public struct Stamp: Sendable {
        /// The absolute floor after appending and evicting.
        public let baseSequence: UInt64
        /// Sequence at which the appended chunk began.
        public let startSequence: UInt64
        /// Sequence immediately after the appended chunk.
        public let currentSequence: UInt64
    }

    /// A replay frame plus its bounded live-update stream.
    public struct Subscription: Sendable {
        public let id: UUID
        public let replay: MobileTerminalLaneOutputFrame
        public let updates: AsyncStream<MobileTerminalLaneOutputFrame>

        fileprivate init(
            id: UUID,
            replay: MobileTerminalLaneOutputFrame,
            updates: AsyncStream<MobileTerminalLaneOutputFrame>
        ) {
            self.id = id
            self.replay = replay
            self.updates = updates
        }
    }

    private struct Subscriber {
        let continuation: AsyncStream<MobileTerminalLaneOutputFrame>.Continuation
    }

    private var buffer = Data()
    private var baseSequence: UInt64 = 0
    private let limit: Int
    private var source: (any LocalLinuxOutputSource)?
    private var sourceIdentity: ObjectIdentifier?
    private var pumpTask: Task<Void, Never>?
    private var pumpGeneration: UUID?
    /// Set once the bound source has finished. A ring cannot bind a new
    /// source, and a later subscription to the same ended source must receive
    /// a finished live stream instead of waiting forever for a pump that will
    /// never restart.
    private var pumpFinished = false
    private var frameByteLimit = LocalLinuxTerminalLane.maximumOutputByteCount
    private var subscribers: [UUID: Subscriber] = [:]

    public init(limit: Int = LocalLinuxTerminalLane.retainedByteLimit) {
        // A negative budget must not turn eviction into `removeFirst` with a
        // negative count. Clamping is deterministic and preserves the public
        // non-throwing initializer.
        self.limit = max(0, limit)
    }

    public var currentSequence: UInt64 {
        sequenceAfterAppending(byteCount: buffer.count, to: baseSequence)
    }

    /// Appends one output chunk to the history and returns its sequence stamp.
    /// Empty chunks do not consume sequence space.
    @discardableResult
    public func append(_ chunk: Data) -> Stamp {
        appendChunk(chunk)
    }

    /// Returns retained bytes from `cursor`, clamping stale and future cursors
    /// for compatibility with the original ring API. Lane subscriptions use
    /// `validatedSnapshot` below to fail closed on a cursor gap.
    public func snapshot(from cursor: UInt64?) -> Snapshot {
        let current = currentSequence
        let selected = min(max(cursor ?? baseSequence, baseSequence), current)
        let offset = Int(selected - baseSequence)
        return Snapshot(
            baseSequence: selected,
            retainedBaseSequence: baseSequence,
            currentSequence: current,
            bytes: Data(buffer.dropFirst(offset))
        )
    }

    /// Opens one bounded subscriber atomically with its replay snapshot.
    public func subscribe(
        source: any LocalLinuxOutputSource,
        cursor: UInt64?,
        maximumPendingFrames: Int,
        maximumFrameByteCount: Int
    ) throws -> Subscription {
        try bind(source: source)
        frameByteLimit = min(frameByteLimit, max(1, maximumFrameByteCount))

        let replaySnapshot = try validatedSnapshot(from: cursor)
        let replay = MobileTerminalLaneOutputFrame(
            kind: .replay,
            retainedBaseSequence: replaySnapshot.retainedBaseSequence,
            sequence: replaySnapshot.baseSequence,
            currentSequence: replaySnapshot.currentSequence,
            bytes: replaySnapshot.bytes
        )

        let id = UUID()
        let capacity = max(1, maximumPendingFrames)
        let streamAndContinuation = AsyncStream<MobileTerminalLaneOutputFrame>.makeStream(
            bufferingPolicy: .bufferingOldest(capacity)
        )
        streamAndContinuation.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeSubscriber(id: id) }
        }
        subscribers[id] = Subscriber(continuation: streamAndContinuation.continuation)
        if pumpFinished {
            // `finishPump` already ended all subscribers that were attached at
            // EOF. Finish this late subscriber too, while preserving the
            // replay frame returned above.
            streamAndContinuation.continuation.finish()
        }
        return Subscription(id: id, replay: replay, updates: streamAndContinuation.stream)
    }

    /// Removes and finishes one subscriber. Finishing wakes a receive that is
    /// blocked in `AsyncStream.Iterator.next()`.
    public func unsubscribe(_ id: UUID) {
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.finish()
    }

    private func bind(source candidate: any LocalLinuxOutputSource) throws {
        if let sourceIdentity {
            guard sourceIdentity == ObjectIdentifier(candidate) else {
                throw LocalLinuxLaneError.sourceMismatch
            }
        } else {
            source = candidate
            sourceIdentity = ObjectIdentifier(candidate)
            startPump(for: candidate)
        }
    }

    private func startPump(for source: any LocalLinuxOutputSource) {
        guard pumpTask == nil else { return }
        let generation = UUID()
        pumpGeneration = generation
        pumpTask = Task { [weak self, source] in
            for await bytes in source.output {
                guard !Task.isCancelled else { return }
                await self?.ingest(bytes)
            }
            await self?.finishPump(generation: generation)
        }
    }

    private func ingest(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        let frameLimit = max(1, frameByteLimit)
        var offset = 0
        while offset < bytes.count {
            let count = min(frameLimit, bytes.count - offset)
            let chunk = Data(bytes[offset ..< (offset + count)])
            let stamp = appendChunk(chunk)
            let frame = MobileTerminalLaneOutputFrame(
                kind: .chunk,
                // The ring may evict bytes from the beginning of this source
                // chunk. Report a floor no later than the frame start so the
                // coordinator's envelope invariant remains true even when a
                // callback write is larger than the retained replay budget.
                retainedBaseSequence: min(stamp.baseSequence, stamp.startSequence),
                sequence: stamp.startSequence,
                currentSequence: stamp.currentSequence,
                bytes: chunk
            )

            var dropped: [UUID] = []
            for (id, subscriber) in subscribers {
                switch subscriber.continuation.yield(frame) {
                case .enqueued:
                    break
                case .dropped, .terminated:
                    dropped.append(id)
                @unknown default:
                    dropped.append(id)
                }
            }
            for id in dropped {
                unsubscribe(id)
            }
            offset += count
        }
    }

    private func finishPump(generation: UUID) {
        guard pumpGeneration == generation else { return }
        pumpTask = nil
        pumpGeneration = nil
        pumpFinished = true
        // Keep the source binding after EOF. This ring belongs to one pty, and
        // accepting a different source would splice a new process's bytes
        // into the old sequence history. A new session must create a new ring;
        // retaining this closed source is intentional and bounded by that
        // session's owner lifetime.
        let active = Array(subscribers.keys)
        for id in active { unsubscribe(id) }
    }

    private func removeSubscriber(id: UUID) {
        _ = subscribers.removeValue(forKey: id)
    }

    private func appendChunk(_ chunk: Data) -> Stamp {
        let start = currentSequence
        guard !chunk.isEmpty else {
            return Stamp(
                baseSequence: baseSequence,
                startSequence: start,
                currentSequence: start
            )
        }

        buffer.append(chunk)
        let current = sequenceAfterAppending(byteCount: chunk.count, to: start)
        if buffer.count > limit {
            let drop = buffer.count - limit
            buffer.removeFirst(drop)
            baseSequence = sequenceAfterAppending(byteCount: drop, to: baseSequence)
        }
        return Stamp(
            baseSequence: baseSequence,
            startSequence: start,
            currentSequence: current
        )
    }

    private func validatedSnapshot(from cursor: UInt64?) throws -> Snapshot {
        let current = currentSequence
        if let cursor {
            guard cursor >= baseSequence else {
                throw LocalLinuxLaneError.cursorGap(
                    requested: cursor,
                    retainedBase: baseSequence,
                    current: current
                )
            }
            guard cursor <= current else {
                throw LocalLinuxLaneError.cursorAhead(
                    requested: cursor,
                    current: current
                )
            }
        }
        let selected = cursor ?? baseSequence
        let offset = Int(selected - baseSequence)
        return Snapshot(
            baseSequence: selected,
            retainedBaseSequence: baseSequence,
            currentSequence: current,
            bytes: Data(buffer.dropFirst(offset))
        )
    }

    private func sequenceAfterAppending(byteCount: Int, to sequence: UInt64) -> UInt64 {
        let amount = UInt64(byteCount)
        // A real pty cannot produce enough bytes to overflow this counter. Use
        // saturating arithmetic anyway so malformed test sources cannot wrap
        // the monotonic sequence backwards.
        return sequence > UInt64.max - amount ? UInt64.max : sequence + amount
    }
}
