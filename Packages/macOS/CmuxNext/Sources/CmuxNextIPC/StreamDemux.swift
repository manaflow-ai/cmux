internal import CmuxNextCompat
import class CmuxSafeConcurrency.Invariant
internal import class CmuxSafeConcurrency.OnceContinuation
internal import enum CmuxSafeConcurrency.OnceContinuationError
internal import func CmuxSafeConcurrency.withOnceContinuation

/// An item the frame reader routes to a stream: one frame's payload or a decoded event.
public protocol StreamSinkItem: Sendable {
    /// The bytes this item keeps alive while queued (its payload), counted against the sink's byte bound.
    var sinkByteCount: Int { get }
    /// True for an item that starts a fresh state (for terminal output, the snapshot a resync's
    /// snapshot-request returns): a resyncing sink drops every item before it and delivers from it on.
    var startsFreshState: Bool { get }
}

/// Why ``StreamDemux/register(_:limits:resync:)`` refused a stream id.
public enum StreamDemuxError: Error, Sendable, Equatable {
    /// Stream 0 is the connection's control sequence; it never has a sink.
    case reservedStream
    /// The id has a sink that has not seen its stream-end yet (an id is reusable only after stream-end).
    case streamInUse(UInt16)
    /// ``StreamDemux/endAll()`` ran: the connection is gone and no frame or stream-end will come.
    case connectionClosed
}

/// Routes the frames of one connection to per-stream sinks without ever waiting (Chrome's
/// `mojo/public/cpp/bindings/lib/multiplex_router.cc`: one pipe, one endpoint per interface id, and
/// the IO thread only routes).
///
/// - A sink is registered before the open request is sent, so a frame that arrives right after the
///   open always has a sink.
/// - Each sink is bounded (8 MiB and 65,536 items by default, like a Mojo data pipe's fixed capacity,
///   `mojo/core/data_pipe_producer_dispatcher.cc`). Where Mojo's `MessageQuotaChecker` ends a pipe over
///   quota, an overflowing sink drops what it holds, calls its owner's resync hook once and drops every
///   later item until one ``StreamSinkItem/startsFreshState``. A stopped consumer therefore costs its
///   own stream a snapshot and never delays another stream or the control replies.
/// - A frame for a stream with no sink is counted (``unknownItemCount``) until that stream's end.
/// - Connection loss (``endAll()``) is terminal: a later register throws
///   ``StreamDemuxError/connectionClosed`` and a later route returns ``Route/closed``, as
///   `MultiplexRouter` marks an endpoint created after `encountered_error_` peer-closed.
///
/// ``route(_:to:)`` and ``end(_:)`` are called on the reader thread; ``register(_:limits:resync:)`` on any
/// thread. Each takes a short `Mutex` critical section and nothing else.
public final class StreamDemux<Item: StreamSinkItem>: Sendable {
    /// What ``route(_:to:)`` did with an item.
    public enum Route: Sendable, Equatable {
        /// Queued for (or handed to) the stream's consumer.
        case delivered
        /// The sink exists but dropped the item: overflow, resyncing or cancelled.
        case dropped
        /// No sink has this stream id; counted until its stream-end.
        case unknown
        /// The connection was lost (``endAll()``); nothing is routed or counted.
        case closed
    }

    /// A sink's bounds. An item is admitted when the queue is empty even if it alone is larger, so
    /// one oversized frame cannot resync forever.
    public struct Limits: Sendable, Equatable {
        public var maxBytes: Int
        public var maxItems: Int

        public init(maxBytes: Int, maxItems: Int) {
            self.maxBytes = maxBytes
            self.maxItems = maxItems
        }

        /// Terminal output: 8 MiB (p05-ipc design section 3.4; TerminalEventQueue's high water).
        public static var output: Limits { Limits(maxBytes: 8 << 20, maxItems: 1 << 16) }
    }

    private struct Table: Sendable {
        var sinks: [UInt16: Sink] = [:]
        /// Items for streams with no sink, per stream, until that stream's end.
        var unknown: [UInt16: Int] = [:]
        var unknownTotal = 0
        /// Set by ``endAll()`` and never cleared: the demux serves one connection.
        var closed = false

        mutating func forgetUnknown(_ stream: UInt16) {
            if let stale = unknown.removeValue(forKey: stream) { unknownTotal -= stale }
        }
    }

    /// What ``route(_:to:)`` found for a stream id.
    private enum Lookup: Sendable {
        case sink(Sink)
        case unknown
        case closed
    }

    private let defaultLimits: Limits
    private let table = Mutex(Table())

    public init(limits: Limits = .output) {
        defaultLimits = limits
    }

    /// Registers the sink for `stream`. Call it before sending the open (attach-surface, open-stream).
    /// `resync` runs on the reader thread, once per overflow, and must not block: it enqueues the
    /// snapshot-request.
    public func register(
        _ stream: UInt16, limits: Limits? = nil, resync: @escaping @Sendable () -> Void
    ) throws(StreamDemuxError) -> Sink {
        guard stream != 0 else { throw .reservedStream }
        let sink = Sink(stream: stream, limits: limits ?? defaultLimits, resync: resync)
        let refusal = table.withLock { table -> StreamDemuxError? in
            guard !table.closed else { return .connectionClosed }
            guard table.sinks[stream] == nil else { return .streamInUse(stream) }
            table.sinks[stream] = sink
            // Frames counted as unknown belong to an older use of the id that never saw its end.
            table.forgetUnknown(stream)
            return nil
        }
        if let refusal { throw refusal }
        return sink
    }

    /// Reader thread. Hands `item` to the stream's sink; never waits.
    @discardableResult
    public func route(_ item: Item, to stream: UInt16) -> Route {
        let lookup = table.withLock { table -> Lookup in
            if table.closed { return .closed }
            if let sink = table.sinks[stream] { return .sink(sink) }
            table.unknown[stream, default: 0] += 1
            table.unknownTotal += 1
            return .unknown
        }
        switch lookup {
        case .sink(let sink):
            return sink.push(item) ? .delivered : .dropped
        case .unknown:
            return .unknown
        case .closed:
            return .closed
        }
    }

    /// Reader thread, on the stream's stream-end. The consumer gets what is queued, then nil; the id is
    /// free again.
    public func end(_ stream: UInt16) {
        let sink = table.withLock { table -> Sink? in
            table.forgetUnknown(stream)
            return table.sinks.removeValue(forKey: stream)
        }
        sink?.finish()
    }

    /// Connection loss ends every stream, and every later register and route sees the loss.
    public func endAll() {
        let sinks = table.withLock { table -> [Sink] in
            let sinks = Array(table.sinks.values)
            table = Table()
            table.closed = true
            return sinks
        }
        for sink in sinks { sink.finish() }
    }

    /// Items routed to streams that have no sink and no stream-end yet.
    public var unknownItemCount: Int { table.withLock { $0.unknownTotal } }

    /// One stream's bounded queue: the reader pushes, one consumer awaits ``next()``.
    public final class Sink: Sendable {
        public let stream: UInt16
        public let limits: Limits
        private let resync: @Sendable () -> Void
        private let state = Mutex(State())

        private enum Phase: Sendable {
            case open
            /// Overflowed: dropping until an item starts a fresh state.
            case resyncing
            /// The consumer cancelled; items are dropped until the stream-end frees the id.
            case cancelled
            /// The stream ended; the consumer drains what is queued.
            case finished
        }

        private enum Outcome: Sendable {
            case queued
            case handed(OnceContinuation<Item?, OnceContinuationError>)
            case dropped
            case overflowed
        }

        private enum Take: Sendable {
            case now(Item?)
            case parked
        }

        private struct State: Sendable {
            var phase = Phase.open
            /// A two-stack FIFO: `inbox` takes pushes, `outbox` (reversed) serves pops.
            var inbox: [Item] = []
            var outbox: [Item] = []
            var bytes = 0
            /// The parked consumer; set only while the queue is empty.
            var waiter: OnceContinuation<Item?, OnceContinuationError>?
            var overflows = 0
            var droppedItems = 0

            var count: Int { inbox.count + outbox.count }

            mutating func append(_ item: Item) {
                inbox.append(item)
                bytes += item.sinkByteCount
            }

            mutating func pop() -> Item? {
                if outbox.isEmpty {
                    guard !inbox.isEmpty else { return nil }
                    outbox = inbox.reversed()
                    inbox.removeAll(keepingCapacity: true)
                }
                guard let item = outbox.popLast() else { return nil }
                bytes -= item.sinkByteCount
                return item
            }

            mutating func dropQueued() {
                droppedItems += count
                inbox.removeAll()
                outbox.removeAll()
                bytes = 0
            }

            mutating func takeWaiter() -> OnceContinuation<Item?, OnceContinuationError>? {
                defer { waiter = nil }
                return waiter
            }
        }

        init(stream: UInt16, limits: Limits, resync: @escaping @Sendable () -> Void) {
            self.stream = stream
            self.limits = limits
            self.resync = resync
        }

        /// Reader thread. True when the item is queued or handed over.
        func push(_ item: Item) -> Bool {
            let outcome = state.withLock { state -> Outcome in
                switch state.phase {
                case .cancelled, .finished:
                    state.droppedItems += 1
                    return .dropped
                case .resyncing:
                    guard item.startsFreshState else {
                        state.droppedItems += 1
                        return .dropped
                    }
                    state.phase = .open
                case .open:
                    break
                }
                if let waiter = state.takeWaiter() { return .handed(waiter) }
                let fits = state.count < limits.maxItems && state.bytes + item.sinkByteCount <= limits.maxBytes
                if fits || state.count == 0 {
                    state.append(item)
                    return .queued
                }
                state.dropQueued()
                // A fresh state supersedes everything queued before it: nothing to resync.
                if item.startsFreshState {
                    state.append(item)
                    return .queued
                }
                state.droppedItems += 1
                state.overflows += 1
                state.phase = .resyncing
                return .overflowed
            }
            switch outcome {
            case .queued:
                return true
            case .handed(let waiter):
                waiter.resume(returning: item)
                return true
            case .dropped:
                return false
            case .overflowed:
                resync()
                return false
            }
        }

        func finish() {
            let waiter = state.withLock { state -> OnceContinuation<Item?, OnceContinuationError>? in
                if state.phase != .cancelled { state.phase = .finished }
                return state.takeWaiter()
            }
            waiter?.resume(returning: nil)
        }

        /// The next item in stream order, or nil once the stream ended and is drained, the sink was
        /// cancelled, or the waiting task was cancelled. One consumer at a time.
        public func next() async -> Item? {
            await withTaskCancellationHandler {
                // A dropped waiter reads as the end of the stream (nil).
                try? await withOnceContinuation { (continuation: OnceContinuation<Item?, OnceContinuationError>) in
                    let take = state.withLock { state -> Take in
                        if let item = state.pop() { return .now(item) }
                        if Task.isCancelled || state.phase == .finished || state.phase == .cancelled {
                            return .now(nil)
                        }
                        guard state.waiter == nil else {
                            Invariant.debugCheck(false, "stream-demux-sink-one-consumer",
                                                 "StreamDemux.Sink has one consumer; a second next() returns nil")
                            return .now(nil)
                        }
                        state.waiter = continuation
                        return .parked
                    }
                    if case .now(let item) = take { continuation.resume(returning: item) }
                }
            } onCancel: {
                let waiter = state.withLock { $0.takeWaiter() }
                waiter?.resume(returning: nil)
            }
        }

        /// The consumer is gone (a view detached): drop what is queued and every later item. The id stays
        /// taken until the stream-end that the owner's cancel-stream produces.
        public func cancel() {
            let waiter = state.withLock { state -> OnceContinuation<Item?, OnceContinuationError>? in
                state.dropQueued()
                state.phase = .cancelled
                return state.takeWaiter()
            }
            waiter?.resume(returning: nil)
        }

        /// Bytes queued for the consumer.
        public var queuedBytes: Int { state.withLock { $0.bytes } }
        /// Items queued for the consumer.
        public var queuedItems: Int { state.withLock { $0.count } }
        /// Overflows so far; each one called the resync hook once.
        public var overflowCount: Int { state.withLock { $0.overflows } }
        /// Items dropped by overflow, resync, cancel or after the end.
        public var droppedItemCount: Int { state.withLock { $0.droppedItems } }
        /// True between an overflow and the next item that starts a fresh state.
        public var isResyncing: Bool { state.withLock { $0.phase == .resyncing } }
    }
}
