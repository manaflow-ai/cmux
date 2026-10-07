import Foundation

struct TimeoutError: Error {}

/// Fails instead of hanging when `operation` does not finish in `limit`.
func within<T: Sendable>(_ limit: Duration = .seconds(5), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw TimeoutError()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
