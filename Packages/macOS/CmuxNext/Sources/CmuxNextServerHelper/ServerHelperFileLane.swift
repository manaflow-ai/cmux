public import CmuxNextCompat
import Dispatch

/// The privileged helper's one lane for blocking work: a serial queue that its
/// file reads and writes run on, off Swift's cooperative pool and never under a
/// lock. The helper is its own small process without the app's BackgroundWork,
/// so this is its ``MayBlockRunner`` (Chrome gives each process its own thread
/// pool the same way, base/task/thread_pool/thread_pool_impl.h).
///
/// Each item runs at its priority's QoS on the one queue, so items run in the
/// order they were queued. The helper has no quit sequence (launchd ends it),
/// so ``MayBlockShutdown`` changes nothing here.
///
/// Built once in the helper's `main.swift` and passed to the store by `init`.
public final nonisolated class ServerHelperFileLane: MayBlockRunner {
    private let queue: DispatchQueue

    /// - Parameter label: The queue's label, which shows in crash reports.
    public init(label: String = "com.cmuxterm.server-helper.files") {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    public func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async(qos: priority.qos, flags: .enforceQoS) {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    public func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                       _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runFiles(priority, shutdown: shutdown, site: site, body)
    }

    public func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runFiles(priority, shutdown: shutdown, site: site, body)
    }

    public func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                          _ body: @escaping @Sendable () -> Void) {
        queue.async(qos: priority.qos, flags: .enforceQoS) { body() }
    }
}
