extension TaskLocal {
    /// Binds this task local to `value` for `body`, inside a Swift task: the current one, else an
    /// immediate main-actor task that finishes before this returns (`body` never suspends).
    /// cx-bpcj, cx-t7hu.
    ///
    /// A binding made where no task is current (a run-loop block, an AppKit event) lives in the
    /// thread's fallback storage. When an isolated deinit then runs inline on the main thread, the
    /// Swift 6.2 runtime pushes a stop-lookup marker onto that storage from its global task
    /// allocator and pops it with `free()`, a pointer malloc never returned: heap corruption,
    /// which trapped the app under CEF on home.show, tab.search and tab.setIcon. Inside a task both
    /// the push and the pop use the task's allocator. CmuxNext binds task locals only through this
    /// (scripts/cmux-next/check-concurrency.sh enforces it).
    @MainActor
    public func withValueInTask<R>(_ value: Value, operation body: () -> R) -> R {
        // The only sanctioned synchronous bindings (check-concurrency: task-local bindings).
        if withUnsafeCurrentTask(body: { $0 != nil }) { return withValue(value, operation: body) }
        // Task.immediate is macOS 26. The marker push above is in the Swift 6.2 concurrency runtime,
        // which ships with macOS 26; macOS 14 and 15 run their own older runtime, which does not
        // push it, so the plain binding is safe there (plans/cmux-next/macos-floor.md).
        guard #available(macOS 26, *) else { return withValue(value, operation: body) }
        return withoutActuallyEscaping(body) { body in
            let run = ImmediateRun { self.withValue(value, operation: body) }
            // task-owner: runs to its end before `finish` returns; `body` never suspends
            _ = Task.immediate { @MainActor in run.start() }
            return run.finish()
        }
    }
}

/// One body that either the immediate task or its caller runs, exactly once.
private final class ImmediateRun<T> {
    private enum State {
        case pending(() -> T)
        case done(T)
    }

    private var state: State

    init(_ body: @escaping () -> T) { state = .pending(body) }

    // Released where no task may be current: teardown must not need a main-actor hop.
    nonisolated deinit {}

    func start() {
        guard case .pending(let body) = state else { return }
        state = .done(body())
    }

    /// The result, with the body released before `withoutActuallyEscaping` checks that it did
    /// not escape.
    func finish() -> T {
        switch state {
        case .done(let value):
            return value
        case .pending(let body):
            // Task.immediate on the main actor starts at once from the main thread; should it ever
            // not, the binding below is the crash this file exists to prevent.
            assertionFailure("Task.immediate did not start synchronously on the main actor")
            let value = body()
            state = .done(value)
            return value
        }
    }
}
