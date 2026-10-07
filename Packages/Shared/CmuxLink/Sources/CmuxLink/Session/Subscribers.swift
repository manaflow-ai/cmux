import Foundation

/// Fan-out of one value stream to many `AsyncStream` subscribers.
struct Subscribers<Value: Sendable>: Sendable {
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]
    private(set) var isFinished = false
    private let policy: AsyncStream<Value>.Continuation.BufferingPolicy

    init(policy: AsyncStream<Value>.Continuation.BufferingPolicy = .unbounded) {
        self.policy = policy
    }

    var isEmpty: Bool { continuations.isEmpty }

    /// A new stream. `initial` values are delivered first. The caller must
    /// remove the id on termination through `onTermination`.
    mutating func add(
        initial: [Value],
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream<Value>.makeStream(bufferingPolicy: policy)
        for value in initial { continuation.yield(value) }
        if isFinished {
            continuation.finish()
            return stream
        }
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in onTermination(id) }
        return stream
    }

    mutating func remove(_ id: UUID) {
        continuations[id] = nil
    }

    func yield(_ value: Value) {
        for continuation in continuations.values { continuation.yield(value) }
    }

    mutating func finish() {
        isFinished = true
        let all = continuations.values
        continuations.removeAll()
        for continuation in all { continuation.finish() }
    }
}
