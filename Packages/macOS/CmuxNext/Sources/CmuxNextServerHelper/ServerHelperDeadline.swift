public import Foundation

/// A helper call or a `pmset` run took longer than its limit.
public nonisolated struct ServerHelperTimedOut: Error, Equatable {
    public init() {}
}

/// Bounds a helper operation with an injected clock (no timers, no sleeps in
/// runtime code). `onTimeout` must make the operation finish (kill the child,
/// invalidate the connection); the call then throws `ServerHelperTimedOut`.
public nonisolated enum ServerHelperDeadline {
    private enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case timedOut
    }

    public static func run<T: Sendable>(
        limit: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        try await withThrowingTaskGroup(of: Outcome<T>.self) { group in
            group.addTask { .value(try await operation()) }
            group.addTask {
                try await clock.sleep(for: limit)
                return .timedOut
            }
            guard let first = try await group.next() else { throw ServerHelperTimedOut() }
            switch first {
            case let .value(value):
                group.cancelAll()
                return value
            case .timedOut:
                onTimeout()
                // The operation ends now (onTimeout's contract); its result or error is dropped.
                while (try? await group.next()) != nil {}
                throw ServerHelperTimedOut()
            }
        }
    }
}

/// One allowlisted child process, killable from the deadline.
final nonisolated class FixChild: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()

    init(_ executable: URL, _ arguments: [String]) {
        process.executableURL = executable
        process.arguments = arguments
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
    }

    func start() async throws -> FixRunResult {
        let pipe = pipe
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                // concurrency-allow: Process.terminationHandler runs on a background queue, never the main thread; pmset -g custom prints about 1 KiB, far below the pipe buffer, so it never blocks the child before exit
                let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
                continuation.resume(returning: FixRunResult(status: finished.terminationStatus, output: String(decoding: data.prefix(65_536), as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Kills only this child (the process the helper started).
    func kill() {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
