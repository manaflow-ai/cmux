import Foundation

/// Bounds link I/O even if the underlying receive does not observe cancellation.
/// The owner supplies cleanup for abandoned I/O and for a resource opened too late.
public enum LinkDeadline {
    public static func run<Value: Sendable>(
        timeout: Duration,
        timeoutError: LinkError = LinkError(code: "reply_timeout", message: "The Mac didn't answer. Retry."),
        operation: @escaping @Sendable () async throws -> Value,
        onCancel: @escaping @Sendable () async -> Void = {},
        onDiscard: @escaping @Sendable (Value) async -> Void = { _ in }
    ) async throws -> Value {
        // Unstructured workers do not inherit a caller's cancellation.
        try Task.checkCancellation()
        let race = LinkDeadlineRace(timeout: timeout, timeoutError: timeoutError,
                                    operation: operation, onCancel: onCancel, onDiscard: onDiscard)
        if timeout <= .zero {
            race.abandon(timeoutError)
            throw timeoutError
        }
        return try await race.value()
    }
}

private final class LinkDeadlineRace<Value: Sendable>: @unchecked Sendable { // crash-allow: immutable callbacks and lock-guarded state
    private let timeout: Duration
    private let timeoutError: LinkError
    private let operation: @Sendable () async throws -> Value
    private let onCancel: @Sendable () async -> Void
    private let onDiscard: @Sendable (Value) async -> Void
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    init(timeout: Duration, timeoutError: LinkError,
         operation: @escaping @Sendable () async throws -> Value,
         onCancel: @escaping @Sendable () async -> Void,
         onDiscard: @escaping @Sendable (Value) async -> Void) {
        self.timeout = timeout
        self.timeoutError = timeoutError
        self.operation = operation
        self.onCancel = onCancel
        self.onDiscard = onDiscard
    }

    // Keep cancellation, continuation registration and task creation in separate
    // methods to keep the generic closure tree small during compilation.
    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await wait()
        } onCancel: {
            self.cancel()
        }
    }

    private func wait() async throws -> Value {
        try await withCheckedThrowingContinuation(start)
    }

    private func start(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let work = Task { await self.execute() }
        let timer = Task { await self.expire() }
        install(work: work, timer: timer)
    }

    private func execute() async {
        // Cancellation can win before start has installed the task handles.
        guard isActive() else { return }
        do {
            try Task.checkCancellation()
            let value = try await operation()
            if !finish(.success(value)) { discard(value) }
        } catch { finish(.failure(error)) }
    }

    private func expire() async {
        do { try await Task.sleep(for: timeout) } catch { return }
        abandon(timeoutError)
    }

    private func cancel() {
        abandon(CancellationError())
    }

    func abandon(_ error: any Error) {
        if finish(.failure(error)) { cleanup() }
    }

    // Fresh tasks run cleanup even when the winning timer or worker was cancelled.
    private func cleanup() {
        Task { await self.onCancel() }
    }

    private func discard(_ value: Value) {
        Task { await self.onDiscard(value) }
    }

    private func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return result == nil
    }

    private func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { tasks = [work, timer] }
        lock.unlock()
        if finished { work.cancel(); timer.cancel() }
    }

    @discardableResult
    private func finish(_ result: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        let continuation = self.continuation
        let tasks = self.tasks
        self.continuation = nil
        self.tasks = []
        lock.unlock()
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
        return true
    }
}
