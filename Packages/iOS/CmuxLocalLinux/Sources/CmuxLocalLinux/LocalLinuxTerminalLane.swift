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
}

extension LocalLinuxSession: LocalLinuxOutputSource {}

/// Receives terminal input bytes typed into a lane. The controller installs a
/// sink that forwards to its single bounded input queue, so the lane and the
/// Ghostty delegate share one input entrypoint.
public typealias LocalLinuxLaneInputSink = @Sendable (Data) -> Void

/// Errors raised while driving a local Linux lane.
public nonisolated enum LocalLinuxLaneError: Error, Equatable, Sendable {
    case closed
    case cursorGap(requested: UInt64, retainedBase: UInt64, current: UInt64)
    case cursorAhead(requested: UInt64, current: UInt64)
    case sourceMismatch
    case concurrentReceive
}

/// One local iSH pty exposed through the same sequence-aware lane contract as
/// a paired Mac terminal.
///
/// A lane is an output attachment, not the owner of the shell process.
/// `close()` detaches the lane so the coordinator can reopen after a transient
/// stream failure; the shell keeps running and its ring keeps retaining output.
/// Input typed through the lane is forwarded to the controller's queue.
public actor LocalLinuxTerminalLane: MobileTerminalLaneConnection {
    /// Maximum output payload in one frame. Large callback writes are split so
    /// one kernel write cannot monopolise the lane or allocate an unbounded
    /// frame in the consumer.
    public static let maximumOutputByteCount = 256 * 1_024

    /// Retained replay budget per terminal.
    public static let retainedByteLimit = 512 * 1_024

    private let source: any LocalLinuxOutputSource
    private let ring: LocalLinuxScrollbackRing
    private let input: LocalLinuxLaneInputSink
    private let requestedCursor: UInt64?
    private var nextSubscriptionCursor: UInt64?
    private var subscriptionID: UUID?
    private var updates: AsyncStream<MobileTerminalLaneOutputFrame>?
    private var receiveInFlight = false
    private var closed = false

    /// Creates a lane over any local pty source.
    /// - Parameters:
    ///   - source: The pty output source shared with `ring`.
    ///   - ring: The retained history and fan-out hub for that source.
    ///   - cursor: Absolute sequence to resume from, or `nil` for the full
    ///     retained history.
    ///   - input: Receives bytes passed to ``sendInput(_:)``.
    public init(
        source: any LocalLinuxOutputSource,
        ring: LocalLinuxScrollbackRing,
        cursor: UInt64? = nil,
        input: @escaping LocalLinuxLaneInputSink = { _ in }
    ) {
        self.source = source
        self.ring = ring
        self.input = input
        self.requestedCursor = cursor
        self.nextSubscriptionCursor = cursor
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

        while !closed {
            if subscriptionID == nil {
                let subscription = try await ring.subscribe(
                    source: source,
                    cursor: nextSubscriptionCursor,
                    maximumPendingFrames: 64,
                    maximumFrameByteCount: Self.maximumOutputByteCount
                )
                nextSubscriptionCursor = nil

                // A cancelled open must not leave a subscriber behind. The
                // ring starts its source pump as part of `subscribe`, so
                // cleanup is required even when cancellation wins before the
                // replay returns.
                do {
                    try Task.checkCancellation()
                } catch {
                    await ring.unsubscribe(subscription.id)
                    throw error
                }

                // `close()` can run while the actor is suspended in
                // `subscribe`. Do not install a subscription after teardown;
                // otherwise its continuation would keep the source alive.
                guard !closed else {
                    await ring.unsubscribe(subscription.id)
                    return nil
                }

                subscriptionID = subscription.id
                updates = subscription.updates
                return subscription.replay
            }

            guard let updates, let subscriptionID else { return nil }
            // Keep the mutable iterator local to the nonisolated `next()`
            // call. Storing it in an actor and passing it across an await
            // triggers the Swift 6 sending-risks diagnostic. AsyncStream
            // keeps its cursor in shared storage, so a fresh iterator
            // continues this lane's queue.
            var iterator = updates.makeAsyncIterator()
            let next = await iterator.next()

            do {
                try Task.checkCancellation()
            } catch {
                self.subscriptionID = nil
                self.updates = nil
                await ring.unsubscribe(subscriptionID)
                throw error
            }

            // `next()` suspends. Teardown may have finished the stream while
            // it was suspended, so check the state before accepting the
            // result.
            guard !closed else { return nil }

            guard let frame = next else {
                self.subscriptionID = nil
                self.updates = nil
                let overflowed = await ring.consumeSubscriberOverflow(subscriptionID)
                await ring.unsubscribe(subscriptionID)
                if overflowed {
                    // The ring dropped this subscriber because its bounded
                    // queue filled. Reattach at the retained history floor;
                    // the next replay is marked explicitly so Ghostty can
                    // reset its model before applying the recovered suffix.
                    nextSubscriptionCursor = nil
                    continue
                }
                return nil
            }
            return frame
        }
        return nil
    }

    /// Forwards one UTF-8 terminal-input operation to the controller's queue.
    /// Raw bytes with control sequences should use the controller directly;
    /// this entrypoint exists for the shared lane protocol.
    public func sendInput(_ text: String) async throws {
        guard !closed else { throw LocalLinuxLaneError.closed }
        try Task.checkCancellation()
        let bytes = Data(text.utf8)
        guard !bytes.isEmpty else { return }
        input(bytes)
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

}

/// A bounded, sequence-aware output history and fan-out hub for one local pty.
///
/// The hub is the sole consumer of `LocalLinuxOutputSource.output`. It appends
/// every callback write before yielding to a bounded subscriber stream. This
/// keeps replay continuity across lane attachments and turns slow-consumer
/// pressure into a clean stream finish, which the coordinator can recover by
/// reopening from its cursor.
public actor LocalLinuxScrollbackRing {
    struct Snapshot: Sendable {
        /// The selected start sequence.
        let baseSequence: UInt64
        /// The absolute floor still retained by the ring. This can be lower
        /// than `baseSequence` when a cursor selects a suffix.
        let retainedBaseSequence: UInt64
        let currentSequence: UInt64
        let bytes: Data
    }

    struct Stamp: Sendable {
        /// The absolute floor after appending and evicting.
        let baseSequence: UInt64
        /// Sequence at which the appended chunk began.
        let startSequence: UInt64
        /// Sequence immediately after the appended chunk.
        let currentSequence: UInt64
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
    private var overflowedSubscriberIDs: Set<UUID> = []
    private let sourceEndedContinuation: AsyncStream<Void>.Continuation

    /// Finishes once the bound source's output stream has ended, whether by a
    /// natural process exit or an explicit hangup. The owner of the shell
    /// awaits this to learn that its session is over; lanes never decide that.
    /// Iterating this stream from a cancelled task returns immediately.
    public nonisolated let sourceEnded: AsyncStream<Void>

    public init(limit: Int = LocalLinuxTerminalLane.retainedByteLimit) {
        // A negative budget must not turn eviction into `removeFirst` with a
        // negative count. Clamping is deterministic and preserves the public
        // non-throwing initializer.
        self.limit = max(0, limit)
        let ended = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        sourceEnded = ended.stream
        sourceEndedContinuation = ended.continuation
    }

    public var currentSequence: UInt64 {
        sequenceAfterAppending(byteCount: buffer.count, to: baseSequence)
    }

    /// Binds this ring to one output source and starts draining it immediately.
    ///
    /// Call this as soon as a session is installed, before a terminal lane is
    /// attached. The source stream can buffer output before its first consumer;
    /// starting the ring here moves those bytes into this ring's bounded replay
    /// buffer and prevents a detached shell from growing that source buffer.
    /// Calling this method again with the same source is a no-op. A ring cannot
    /// be rebound to a different source because that would mix two processes in
    /// one absolute sequence space.
    ///
    /// - Parameter source: The sole pty output source for this ring.
    /// - Throws: ``LocalLinuxLaneError/sourceMismatch`` when already bound to a
    ///   different source.
    public func start(source candidate: any LocalLinuxOutputSource) throws {
        try bind(source: candidate)
    }

    /// Appends one output chunk to the history and returns its sequence stamp.
    /// Empty chunks do not consume sequence space. Production output arrives
    /// through the bound source pump; this seam exists for arithmetic tests.
    @discardableResult
    func append(_ chunk: Data) -> Stamp {
        appendChunk(chunk)
    }

    /// Opens one bounded subscriber atomically with its replay snapshot.
    public func subscribe(
        source: any LocalLinuxOutputSource,
        cursor: UInt64?,
        maximumPendingFrames: Int,
        maximumFrameByteCount: Int
    ) throws -> Subscription {
        try start(source: source)
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
        overflowedSubscriberIDs.remove(id)
        guard let subscriber = subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.finish()
    }

    /// Consumes the one-shot overflow marker for a subscriber whose stream
    /// finished because its bounded queue was full. A lane uses this to
    /// distinguish a recoverable slow-consumer detach from natural pty EOF.
    public func consumeSubscriberOverflow(_ id: UUID) -> Bool {
        overflowedSubscriberIDs.remove(id) != nil
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
                guard !Task.isCancelled else { break }
                await self?.ingest(bytes)
            }
            // Finish the subscriber streams even when the pump is cancelled.
            // Returning early here would leave a waiting lane suspended
            // forever and would allow a same-source reattach to observe an
            // apparently live stream with no producer.
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
            var overflowed = Set<UUID>()
            for (id, subscriber) in subscribers {
                switch subscriber.continuation.yield(frame) {
                case .enqueued:
                    break
                case .dropped:
                    dropped.append(id)
                    overflowed.insert(id)
                case .terminated:
                    dropped.append(id)
                @unknown default:
                    dropped.append(id)
                }
            }
            for id in dropped {
                if overflowed.contains(id) {
                    // Keep the reason after removing the subscriber. The lane
                    // consumes it when its pending iterator reaches EOF.
                    overflowedSubscriberIDs.insert(id)
                    guard let subscriber = subscribers.removeValue(forKey: id) else { continue }
                    subscriber.continuation.finish()
                } else {
                    unsubscribe(id)
                }
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
        sourceEndedContinuation.finish()
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

    /// Returns retained bytes from `cursor`, failing closed when the cursor
    /// points below the retained floor or ahead of the current sequence.
    func validatedSnapshot(from cursor: UInt64?) throws -> Snapshot {
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
