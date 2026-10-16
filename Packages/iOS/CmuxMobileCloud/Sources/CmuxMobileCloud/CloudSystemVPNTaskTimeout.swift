import Foundation

/// Bounds a single Cloud system VPN operation and cancels the underlying task
/// when the caller or the deadline wins.
struct CloudSystemVPNTaskTimeout: Sendable {
    let timeout: Duration

    func value<T: Sendable>(_ task: Task<T, any Error>) async throws -> T {
        let race = Race()
        let cancellation = Cancellation<T>()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
            Task { await cancellation.install(continuation, race: race) }
            let valueTask = Task {
                do {
                    let value = try await task.value
                    guard await race.win() else { return }
                    continuation.yield(value)
                    continuation.finish()
                } catch {
                    guard await race.win() else { return }
                    continuation.finish(throwing: error)
                }
            }
            let timeoutTask = Task {
                do {
                    try await ContinuousClock().sleep(for: timeout)
                } catch {
                    return
                }
                guard await race.win() else { return }
                continuation.finish(throwing: Failure.timedOut)
            }
            continuation.onTermination = { _ in
                task.cancel()
                valueTask.cancel()
                timeoutTask.cancel()
            }
        }

        return try await withTaskCancellationHandler(operation: {
            for try await value in stream {
                return value
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            throw Failure.timedOut
        }, onCancel: {
            Task { await cancellation.cancel(race: race) }
        })
    }

}
