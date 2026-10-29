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
        // Do not create an unstructured worker for an already-cancelled caller.
        // `Task {}` does not inherit cancellation, so relying on the worker's
        // first check alone leaves a small window where operation can start.
        try Task.checkCancellation()
        guard timeout > .zero else {
            Task { await onCancel() }
            throw timeoutError
        }
        let race = LinkDeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let work = Task {
                    do {
                        guard race.beginOperation() else { return }
                        try Task.checkCancellation()
                        let value = try await operation()
                        if !race.finish(.success(value)) { Task { await onDiscard(value) } }
                    } catch { race.finish(.failure(error)) }
                }
                let timer = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    if race.finish(.failure(timeoutError)) { Task { await onCancel() } }
                }
                race.install(work: work, timer: timer)
            }
        } onCancel: {
            if race.finish(.failure(CancellationError())) { Task { await onCancel() } }
        }
    }
}

private final class LinkDeadlineRace<Value: Sendable>: @unchecked Sendable { // crash-allow: lock-guarded state
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let result: Result<Value, any Error>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let result { continuation.resume(with: result) }
    }

    func install(work: Task<Void, Never>, timer: Task<Void, Never>) {
        let finished = lock.withLock {
            guard result == nil else { return true }
            tasks = [work, timer]
            return false
        }
        if finished { work.cancel(); timer.cancel() }
    }

    /// Claims the operation slot only while the race is still active. This
    /// closes the gap between creating the worker and installing its handle.
    func beginOperation() -> Bool {
        lock.withLock { result == nil }
    }

    @discardableResult
    func finish(_ result: Result<Value, any Error>) -> Bool {
        let settled = lock.withLock { () -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>])? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { continuation = nil; tasks = [] }
            return (continuation, tasks)
        }
        guard let (continuation, tasks) = settled else { return false }
        for task in tasks { task.cancel() }
        continuation?.resume(with: result)
        return true
    }
}
