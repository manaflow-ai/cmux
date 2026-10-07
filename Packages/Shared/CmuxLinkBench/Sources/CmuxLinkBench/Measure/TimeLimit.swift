import Foundation

/// A wall-clock limit for one benchmark step.
struct TimeLimit: Sendable {
    let limit: Duration

    init(_ limit: Duration) {
        self.limit = limit
    }

    /// Runs `operation`; on timeout it is cancelled and abandoned (a step
    /// stuck in a non-cancellable wait cannot hang the run) and nil is returned.
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T? {
        let gate = FirstResult<T?>()
        let work = Task {
            do { await gate.resolve(.success(try await operation())) } catch { await gate.resolve(.failure(error)) }
        }
        let timer = Task {
            try? await Task.sleep(for: limit)
            await gate.resolve(.success(nil))
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return try await gate.value()
    }
}
