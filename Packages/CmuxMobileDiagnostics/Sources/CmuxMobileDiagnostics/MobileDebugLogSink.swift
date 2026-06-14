public import Foundation

/// Append-only ring buffer of recent debug log lines, owned by an `actor` so
/// concurrent writers from Ghostty IO/render threads serialize without a lock.
///
/// This replaces the previous `Synchronization.Mutex`-backed store. Mutation
/// happens through ``append(_:)`` (each line is timestamped with seconds since
/// the sink was created), and observers can subscribe to ``lines()`` for a live
/// `AsyncStream` of every appended line or pull the whole buffer with
/// ``snapshot()``.
public actor MobileDebugLogSink {
    private var buffer: [String] = []
    private let capacity: Int
    private let startedAt: Date
    private let now: @Sendable () -> Date
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]

    /// Create a sink.
    ///
    /// - Parameters:
    ///   - capacity: Maximum number of retained lines. Oldest lines are dropped
    ///     once the buffer grows past this. Defaults to `4000`.
    ///   - now: Clock used to timestamp lines and anchor the elapsed offset.
    ///     Injected so tests can pin time; defaults to `Date.init`.
    public init(capacity: Int = 4000, now: @escaping @Sendable () -> Date = { Date() }) {
        self.capacity = capacity
        self.now = now
        self.startedAt = now()
    }

    /// Append one timestamped line (seconds elapsed since the sink was created).
    ///
    /// The line is broadcast to every active ``lines()`` subscriber and stored
    /// in the ring buffer, evicting the oldest entries past the capacity.
    public func append(_ message: String) {
        let elapsed = String(format: "%9.3f", now().timeIntervalSince(startedAt))
        let line = "[\(elapsed)] \(message)"
        buffer.append(line)
        if buffer.count > capacity {
            buffer.removeFirst(buffer.count - capacity)
        }
        for continuation in continuations.values {
            continuation.yield(line)
        }
    }

    /// The full buffer as newline-joined text, newest last.
    public func snapshot() -> String {
        buffer.joined(separator: "\n")
    }

    /// The current buffered lines and their count, newest last.
    ///
    /// - Returns: A tuple of the line count and the newline-joined body. Useful
    ///   when a caller needs both without two round-trips to the actor.
    public func snapshotWithCount() -> (count: Int, body: String) {
        (buffer.count, buffer.joined(separator: "\n"))
    }

    /// Remove every buffered line, keeping the allocated capacity.
    public func clear() {
        buffer.removeAll(keepingCapacity: true)
    }

    /// A live stream of every line appended after subscription.
    ///
    /// The stream finishes when the sink is deinitialized. Cancelling the
    /// consuming task detaches its continuation.
    public func lines() -> AsyncStream<String> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}
