/// Runs synchronous main-thread work inside a Swift task, so task locals bound there stay in
/// the task's own storage (cx-bpcj, cx-t7hu).
///
/// A task-local binding made where no task is current (a run-loop block, an AppKit event) lives
/// in the thread's fallback storage. When an isolated deinit then runs inline on the main thread,
/// the Swift 6.2 runtime pushes a stop-lookup marker onto that storage from its global task
/// allocator and pops it with `free()`, a pointer malloc never returned: heap corruption, which
/// trapped the app under CEF on home.show, tab.search and tab.setIcon. Inside a task both the
/// push and the pop use the task's allocator. Bind a task local synchronously only inside
/// ``run(_:)`` (scripts/cmux-next/check-concurrency.sh enforces it).
public enum TaskContext {
    /// True when the code running now is inside a task.
    public nonisolated static var isInsideTask: Bool { withUnsafeCurrentTask { $0 != nil } }

    /// Runs `body` now and returns its result: in the current task, else in an immediate
    /// main-actor task that finishes before this returns (`body` never suspends).
    public static func run<T>(_ body: () -> T) -> T {
        if isInsideTask { return body() }
        return withoutActuallyEscaping(body) { body in
            let run = ImmediateRun(body)
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
    /// not escape. Should the task not have started at once, the caller runs the body itself.
    func finish() -> T {
        switch state {
        case .done(let value):
            return value
        case .pending(let body):
            let value = body()
            state = .done(value)
            return value
        }
    }
}
