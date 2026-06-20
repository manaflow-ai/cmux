import Foundation

struct RPCTaskTimeout: Sendable {
    func value<T: Sendable>(
        _ task: Task<T, any Error>,
        timeoutNanoseconds: UInt64
    ) async throws -> T {
        let race = RPCTaskTimeoutRace()
        let stream = AsyncThrowingStream<T, any Error> { continuation in
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
                    try await sleep(nanoseconds: timeoutNanoseconds)
                } catch {
                    return
                }
                guard await race.win() else { return }
                continuation.finish(throwing: MobileShellConnectionError.requestTimedOut)
            }
            continuation.onTermination = { _ in
                valueTask.cancel()
                timeoutTask.cancel()
            }
        }
        for try await value in stream {
            return value
        }
        if Task.isCancelled {
            throw CancellationError()
        }
        throw MobileShellConnectionError.requestTimedOut
    }

    func sleep(nanoseconds: UInt64) async throws {
        let capped = min(nanoseconds, UInt64(Int64.max))
        try await ContinuousClock().sleep(for: .nanoseconds(Int64(capped)))
    }

    func remainingNanoseconds(until deadlineUptimeNanoseconds: UInt64) throws -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadlineUptimeNanoseconds else {
            throw MobileShellConnectionError.requestTimedOut
        }
        return deadlineUptimeNanoseconds - now
    }
}
