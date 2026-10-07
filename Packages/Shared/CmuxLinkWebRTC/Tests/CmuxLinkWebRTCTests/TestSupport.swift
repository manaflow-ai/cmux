import Foundation

/// Runs `operation` with a real-time limit so a broken peer fails the test
/// instead of hanging it. The operation runs unstructured, so a step stuck
/// in a non-cancellable wait is abandoned rather than awaited.
func within<T: Sendable>(_ limit: Duration = .seconds(10), _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = Gate<T>()
    let work = Task {
        do { await gate.resolve(.success(try await operation())) } catch { await gate.resolve(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.resolve(.failure(WebRTCTestError.timeout))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await gate.value()
}

/// The first result wins.
actor Gate<T: Sendable> {
    private var result: Result<T, any Error>?
    private var waiters: [CheckedContinuation<T, any Error>] = []

    func resolve(_ outcome: Result<T, any Error>) {
        guard result == nil else { return }
        result = outcome
        for waiter in waiters { waiter.resume(with: outcome) }
        waiters = []
    }

    func value() async throws -> T {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }
}

/// The repository root, from this file's path.
let repositoryRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { url.deleteLastPathComponent() }
    return url
}()
