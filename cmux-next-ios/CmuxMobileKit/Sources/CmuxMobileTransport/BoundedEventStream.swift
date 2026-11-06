import Foundation

/// A lossless async sequence backed by a byte-bounded queue.
///
/// Daemon channels carry both replies and unsolicited event lines. Keeping the
/// events in an unbounded `AsyncStream` lets the daemon reader consume forever
/// even when the terminal renderer is behind, so transport-level flow control
/// never sees the slow consumer. This queue makes the producer wait once the
/// byte budget is full; the reader therefore stops calling `receive()` until a
/// consumer drains some data.
public struct DaemonEventStream: AsyncSequence, Sendable {
    public typealias Element = Data

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let buffer: BoundedDaemonEventBuffer

        init(buffer: BoundedDaemonEventBuffer) {
            self.buffer = buffer
        }

        public mutating func next() async -> Data? {
            await buffer.next()
        }
    }

    let buffer: BoundedDaemonEventBuffer

    init(buffer: BoundedDaemonEventBuffer) {
        self.buffer = buffer
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(buffer: buffer)
    }
}

/// The bounded queue used by `DaemonClient`'s unsolicited event stream.
///
/// There is one producer (the daemon reader) and normally one consumer (the
/// terminal/chat event task), but the implementation tolerates a replacement
/// consumer while preserving FIFO order. `finish()` wakes both sides so a
/// cancelled/closed daemon never leaves a task suspended forever.
public actor BoundedDaemonEventBuffer {
    public static let defaultCapacity = 4 << 20

    private let capacity: Int
    private var queue: [Data] = []
    private var head = 0
    private var queuedBytes = 0
    private var closed = false
    private var consumers: [(id: UUID, continuation: CheckedContinuation<Data?, Never>)] = []
    private var producer: CheckedContinuation<Void, Never>?

    public init(capacity: Int = BoundedDaemonEventBuffer.defaultCapacity, initiallyClosed: Bool = false) {
        self.capacity = max(1, capacity)
        self.closed = initiallyClosed
    }

    /// Enqueues one complete event line. Returns `false` after `finish()`.
    /// A single event larger than the nominal capacity is admitted when the
    /// queue is empty; dropping it would corrupt the terminal stream.
    public func push(_ data: Data) async -> Bool {
        guard !data.isEmpty else { return !closed }
        while !closed && !Task.isCancelled && (queuedBytes + data.count > capacity) && !queue.isEmpty {
            await waitForRoom(for: data.count)
        }
        guard !closed, !Task.isCancelled else { return false }
        if !consumers.isEmpty {
            consumers.removeFirst().continuation.resume(returning: data)
        } else {
            queue.append(data)
            queuedBytes += data.count
        }
        return true
    }

    /// Returns the oldest event, waiting for the next one when needed.
    public func next() async -> Data? {
        guard !Task.isCancelled else { return nil }
        if let data = takeQueuedEvent() { return data }
        if closed { return nil }
        return await waitForEvent(id: UUID())
    }

    private func takeQueuedEvent() -> Data? {
        guard head < queue.count else { return nil }
        let data = queue[head]
        queue[head] = Data()
        head += 1
        queuedBytes -= data.count
        if head >= queue.count {
            queue.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= queue.count {
            queue.removeFirst(head)
            head = 0
        }
        resumeProducerIfRoom()
        return data
    }

    // Keep cancellation and continuation registration in separate functions.
    // Swift's ClosureLifetimeFixup pass can hang on their nested closures.
    private func waitForRoom(for byteCount: Int) async {
        await withTaskCancellationHandler {
            await suspendProducer(for: byteCount)
        } onCancel: {
            self.scheduleProducerCancellation()
        }
    }

    private func suspendProducer(for byteCount: Int) async {
        await withCheckedContinuation { continuation in
            registerProducer(continuation, byteCount: byteCount)
        }
    }

    private func registerProducer(_ continuation: CheckedContinuation<Void, Never>, byteCount: Int) {
        if Task.isCancelled || closed || queue.isEmpty || queuedBytes + byteCount <= capacity {
            continuation.resume()
        } else {
            producer = continuation
        }
    }

    private nonisolated func scheduleProducerCancellation() {
        Task { await self.cancelProducer() }
    }

    private func waitForEvent(id: UUID) async -> Data? {
        await withTaskCancellationHandler {
            await suspendConsumer(id: id)
        } onCancel: {
            self.scheduleConsumerCancellation(id)
        }
    }

    private func suspendConsumer(id: UUID) async -> Data? {
        await withCheckedContinuation { continuation in
            registerConsumer(continuation, id: id)
        }
    }

    private func registerConsumer(_ continuation: CheckedContinuation<Data?, Never>, id: UUID) {
        if Task.isCancelled {
            continuation.resume(returning: nil)
        } else if let data = takeQueuedEvent() {
            continuation.resume(returning: data)
        } else if closed {
            continuation.resume(returning: nil)
        } else {
            consumers.append((id, continuation))
        }
    }

    private nonisolated func scheduleConsumerCancellation(_ id: UUID) {
        Task { await self.cancelConsumer(id) }
    }

    /// Closes the stream and wakes any blocked producer or consumer.
    /// Already queued events remain drainable (the previous AsyncStream EOF
    /// behavior); consumed slots release their data immediately. Cancellation
    /// only removes that waiter, so a replacement consumer can still drain.
    public func finish() {
        guard !closed else { return }
        closed = true
        cancelProducer()
        for consumer in consumers { consumer.continuation.resume(returning: nil) }
        consumers.removeAll()
    }

    public var pendingBytes: Int { queuedBytes }

    private func cancelProducer() {
        producer?.resume()
        producer = nil
    }

    private func cancelConsumer(_ id: UUID) {
        guard let index = consumers.firstIndex(where: { $0.id == id }) else { return }
        consumers.remove(at: index).continuation.resume(returning: nil)
    }

    private func resumeProducerIfRoom() {
        guard queuedBytes < capacity, let producer else { return }
        self.producer = nil
        producer.resume()
    }
}
