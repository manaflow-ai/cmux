/// A task that its holder owns: releasing the handle cancels the task.
///
/// It replaces a stored `Task<Void, Never>?` plus the hand-written `nonisolated deinit` that
/// cancelled it only on the main thread (a main-thread guard and a main-actor assumption): the
/// owner keeps the handle in a stored property and its deinit has no body. `Task.cancel()` is
/// thread-safe, so the handle cancels from whatever thread releases it (the old guard skipped the
/// cancel off the main thread, and the task kept running). Wrap the `Task { ... }` itself, so the
/// closure keeps the isolation it inherits where it is written.
///
/// A main-actor owner still declares `nonisolated deinit {}` (check-concurrency.sh enforces it in
/// main-actor-default targets): its implicit deinit is isolated there, so without one the release
/// hops to the main actor (the cx-t7hu trap inside an action's task-local scope) and the handle is
/// released on the main thread, not on the releasing one.
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

    /// Cancels the task now (also happens when the handle is released).
    public func cancel() {
        task.cancel()
    }

    deinit {
        task.cancel()
    }
}
