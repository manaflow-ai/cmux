import Foundation

/// Bounds a single Cloud system VPN operation and cancels the underlying task
/// when the caller or the deadline wins.
struct CloudSystemVPNTaskTimeout: Sendable {
    enum Failure: Error, Sendable, Equatable {
        case timedOut
    }

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

    private actor Race {
        private var hasWinner = false

        func win() -> Bool {
            guard !hasWinner else { return false }
            hasWinner = true
            return true
        }
    }

    private actor Cancellation<T: Sendable> {
        private var continuation: AsyncThrowingStream<T, any Error>.Continuation?
        private var isCancelled = false

        func install(
            _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
            race: Race
        ) {
            self.continuation = continuation
            if isCancelled {
                finishCancellation(continuation, race: race)
            }
        }

        func cancel(race: Race) {
            isCancelled = true
            guard let continuation else { return }
            finishCancellation(continuation, race: race)
        }

        private func finishCancellation(
            _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
            race: Race
        ) {
            Task {
                guard await race.win() else { return }
                continuation.finish(throwing: CancellationError())
            }
        }
    }
}
