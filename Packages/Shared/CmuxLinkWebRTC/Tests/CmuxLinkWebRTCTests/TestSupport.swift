import Foundation

/// Runs `operation` with a real-time limit so a broken peer fails the test
/// instead of hanging it.
func within<T: Sendable>(_ limit: Duration = .seconds(10), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw WebRTCTestError.timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// The repository root, from this file's path.
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()
