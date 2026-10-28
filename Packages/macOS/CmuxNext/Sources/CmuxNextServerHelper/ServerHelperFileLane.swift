import Dispatch
import class CmuxSafeConcurrency.OnceContinuation
import func CmuxSafeConcurrency.withOnceThrowingContinuation

/// Runs the prior-value store's blocking file reads and writes: off the caller's thread, off
/// Swift's cooperative pool, never under a lock. The store needs files work only, so this
/// seam has nothing else.
public protocol ServerFixPriorFiles: Sendable {
    /// Runs `body` on the files lane and returns its result once it ran.
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T
}

/// The privileged helper's one files lane: a serial queue (Chrome writes a file on its own
/// sequence, base/files/important_file_writer.h). The helper is its own small process without
/// the app's BackgroundWork, so it has this one queue; items run in the order they were queued.
///
/// Built once in the helper's `main.swift` and passed to the store by `init`.
public final nonisolated class ServerHelperFileLane: ServerFixPriorFiles {
    private let queue = DispatchQueue(label: "com.cmuxterm.server-helper.files", qos: .userInitiated)

    public init() {}

    public func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withOnceThrowingContinuation { (continuation: OnceContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
