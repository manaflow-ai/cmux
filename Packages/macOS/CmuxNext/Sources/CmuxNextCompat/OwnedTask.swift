/// A task that its holder owns: releasing the handle cancels the task.
///
/// It replaces a stored `Task<Void, Never>?` plus the hand-written `nonisolated deinit` that
/// cancelled it only on the main thread (a main-thread guard and a main-actor assumption): the
/// owner keeps the handle in a stored property and needs no deinit. `Task.cancel()` is thread-safe, so
/// the handle cancels from whatever thread releases it (the old guard skipped the cancel off the
/// main thread, and the task kept running). Wrap the `Task { ... }` itself, so the closure keeps
/// the isolation it inherits where it is written.
///
/// ```swift
/// watch = OwnedTask(Task { [weak self] in
///     for await status in ObservationStream({ chief.status }) { self?.show(status) }
/// })
/// ```
public final class OwnedTask: Sendable {
    private let task: Task<Void, Never>

    /// Owns `task`: it is cancelled when this handle is released or ``cancel()`` is called.
    ///
    /// - Parameter task: The task to own, usually a `Task { ... }` written at the call site.
    public init(_ task: Task<Void, Never>) {
        self.task = task
    }

    /// Whether the task was cancelled (by ``cancel()`` or otherwise); for tests.
    var isCancelled: Bool { task.isCancelled }

    /// Cancels the task now (also happens when the handle is released).
    public func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
