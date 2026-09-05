public import Foundation

private enum IrxDeadlineOutcome<Value: Sendable>: Sendable {
    case operation(Value?)
    case timeout
}

/// Runs one async operation with an independent deadline.
///
/// The timeout handler must close or release the resource awaited by
/// `operation`. Task cancellation is cooperative, so cancellation alone is
/// not sufficient to bound an operation backed by a lower-level read that
/// ignores cancellation.
public func withIrxDeadline<T: Sendable>(
    _ limit: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> T?
) async throws -> T? {
    let outcomes = AsyncThrowingStream<IrxDeadlineOutcome<T>, any Error> { continuation in
        let operationTask = Task {
            do {
                continuation.yield(.operation(try await operation()))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        let timeoutTask = Task {
            do {
                try await ContinuousClock().sleep(for: limit)
                continuation.yield(.timeout)
                continuation.finish()
            } catch {
                // Cancellation means the operation won the race.
            }
        }
        continuation.onTermination = { _ in
            operationTask.cancel()
            timeoutTask.cancel()
        }
    }

    var iterator = outcomes.makeAsyncIterator()
    guard let outcome = try await iterator.next() else {
        return nil
    }
    switch outcome {
    case .operation(let value):
        return value
    case .timeout:
        // Cleanup can itself cross a cancellation-insensitive native bridge.
        // Start it without making the caller wait for that bridge, otherwise
        // this helper's deadline would be defeated by the cleanup it invokes.
        Task {
            await onTimeout()
        }
        return nil
    }
}
