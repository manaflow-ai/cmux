import Foundation

/// Bridges Swift task cancellation into GCD-hosted git work, where
/// `Task.isCancelled` has no task context and always reads false.
///
/// `offCooperativePool` binds a signal to the worker thread for the duration
/// of the blocking work and flips it from `withTaskCancellationHandler`, so
/// subprocess read loops and bounded file scans can stop early even though
/// they run outside any Swift task.
final class WorkspaceChangesCancellationSignal: @unchecked Sendable {
    private static let threadKey = "com.cmux.workspace-changes.cancellation"
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// The signal bound to the current worker thread, if any.
    static var current: WorkspaceChangesCancellationSignal? {
        Thread.current.threadDictionary[threadKey] as? WorkspaceChangesCancellationSignal
    }

    /// True when the thread-bound signal fired, or (for inline callers that
    /// do run inside a task, such as tests) the surrounding task is cancelled.
    static var isCurrentCancelled: Bool {
        current?.isCancelled ?? Task.isCancelled
    }

    /// Binds the signal to the current thread while `work` runs.
    func withCurrentBinding<T>(_ work: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        dictionary[Self.threadKey] = self
        defer { dictionary.removeObject(forKey: Self.threadKey) }
        return try work()
    }
}
