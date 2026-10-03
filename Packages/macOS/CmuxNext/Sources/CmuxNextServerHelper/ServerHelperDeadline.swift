import Foundation
import Synchronization

/// A helper call or a `pmset` run took longer than its limit.
public nonisolated struct ServerHelperTimedOut: Error, Equatable {
    public init() {}
}

/// Bounds a helper operation with an injected clock, without waiting for the
/// loser (the ControlDeadline pattern): the first of {result, deadline}
/// resumes the caller. On the deadline it runs `onTimeout` (kill the child,
/// invalidate the connection) and throws `ServerHelperTimedOut`; the
/// operation's late result is dropped.
public struct ServerHelperDeadline {
    public init() {}
    public func run<T: Sendable>(
        limit: Duration,
        clock: any Clock<Duration>,
        operation: @escaping @Sendable () async throws -> T,
        onTimeout: @escaping @Sendable () -> Void
    ) async throws -> T {
        let race = Race<T>()
        return try await withCheckedThrowingContinuation { continuation in
            race.begin(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                // wakeup-allow: one-shot deadline of one helper request, cancelled when the request answers
                do { try await clock.sleep(for: limit) } catch { return }
                if race.finish(.failure(ServerHelperTimedOut())) {
                    onTimeout()
                    work.cancel()
                }
            }
            race.onFinish { timer.cancel() }
        }
    }

    private final class Race<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var done = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func begin(_ continuation: CheckedContinuation<T, any Error>) {
            state.withLock { $0.continuation = continuation }
        }

        /// Registers cleanup; runs it now if the race already ended.
        func onFinish(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = state.withLock { state -> Bool in
                if state.done { return true }
                state.cleanup = cleanup
                return false
            }
            if runNow { cleanup() }
        }

        /// True for the first caller, which resumes the waiter.
        @discardableResult
        func finish(_ result: Result<T, any Error>) -> Bool {
            let (continuation, cleanup) = state.withLock { state -> (CheckedContinuation<T, any Error>?, (@Sendable () -> Void)?) in
                guard !state.done else { return (nil, nil) }
                state.done = true
                defer {
                    state.continuation = nil
                    state.cleanup = nil
                }
                return (state.continuation, state.cleanup)
            }
            guard let continuation else { return false }
            continuation.resume(with: result)
            cleanup?()
            return true
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
