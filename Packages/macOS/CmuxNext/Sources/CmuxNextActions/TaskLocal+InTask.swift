extension TaskLocal {
    /// Binds this task local to `value` for `body`, inside a Swift task: the current one, else a
    /// main-actor task that starts synchronously and finishes before this returns (`body` never
    /// suspends). cx-bpcj, cx-t7hu.
    ///
    /// A binding made where no task is current (a run-loop block, an AppKit event) lives in the
    /// thread's fallback storage. When an isolated deinit then runs inline on the main thread, the
    /// runtime (macOS 15.4 and newer: `swift_task_deinitOnExecutor`) pushes a stop-lookup marker
    /// onto that storage from its global task allocator and pops it with `free()`, a pointer
    /// malloc never returned. Under Chromium's allocator that free traps: home.show, tab.search
    /// and tab.setIcon on macOS 26, and on macOS 15.8.1 a Cmd-T that released the previous New Tab
    /// key hold (NEXT 3889579838401, 2026-10-16). Every main-actor class of a main-actor-default
    /// target has an isolated deinit, so the binding must never sit in the fallback storage.
    /// Inside a task both the push and the pop use the task's allocator. CmuxNext binds task
    /// locals only through this (scripts/cmux-next/check-concurrency.sh enforces it).
    ///
    /// Below macOS 15.4 the binding stays in the fallback storage. There the back-deploy shim runs
    /// an isolated deinit inline and pushes no marker, and a task started with `startOnMainActor`
    /// is not safe: when `body` spins a nested run loop that runs other main-actor jobs
    /// (`performClose` highlights the close button), the macOS 14 runtime leaves no current task
    /// after them. The pop and the task's own frame free then go to the no-task allocator and
    /// abort ("freed pointer was not the last allocation"): New Incognito Window, then Close
    /// Window, crashed every time on macOS 14.8.7 (scripts/fuzz/macos-matrix/repros).
    @MainActor
    public func withValueInTask<R>(_ value: Value, operation body: () -> R) -> R {
        // The only sanctioned synchronous bindings (check-concurrency: task-local bindings).
        if withUnsafeCurrentTask(body: { $0 != nil }) { return withValue(value, operation: body) }
        guard #available(macOS 15.4, *) else { return withValue(value, operation: body) }
        return withoutActuallyEscaping(body) { body in
            let run = ImmediateRun { self.withValue(value, operation: body) }
            if #available(macOS 26, *) {
                // task-owner: runs to its end before `finish` returns; `body` never suspends
                _ = Task.immediate { @MainActor in run.start() }
            } else {
                // task-owner: runs to its end before `finish` returns; `body` never suspends
                _ = startTaskOnMainActor { @MainActor in run.start() }
            }
            return run.finish()
        }
    }

    /// Binds this task local to `value` for async `body`, in the task that awaits it. An async caller
    /// always runs in a task, so the binding is the task's own, never the thread's fallback storage.
    /// For work that left its run's task tree (a detached task inherits no task local) and binds the
    /// run's value again.
    public nonisolated func withValueAwaiting<R>(_ value: Value, operation body: () async -> R) async -> R {
        await withValue(value) { await body() }
    }
}

/// `Task.startOnMainActor(priority:_:)` of the Swift 5.9 runtime (macOS 14 and newer): a task that
/// runs on the main thread at once, to its first suspension, before the call returns. It is the
/// macOS 14 to 15 form of `Task.immediate` on the main actor; the SDK declares it as SPI
/// (`@_spi(MainActorUtilities)`) and ships no private interface for it, so this names its exported
/// symbol (libswift_Concurrency.tbd). The symbol is ABI of an ABI-stable library: it never moves.
/// The caller must be on the main executor (the runtime traps otherwise); it saves and restores a current task.
@_silgen_name("$sScTss5NeverORs_rlE16startOnMainActor8priority_ScTyxABGScPSg_xyYaYbScMYccntFZ")
@MainActor
@discardableResult
private func startTaskOnMainActor<Success: Sendable>(
    priority: TaskPriority? = nil,
    _ work: __owned @Sendable @escaping @MainActor () async -> Success
) -> Task<Success, Never>

/// One body that either the synchronously started task or its caller runs, exactly once.
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
            // The task starts at once from the main thread; should it ever not, the binding below
            // is the crash this file exists to prevent.
            assertionFailure("the main-actor task did not start synchronously")
            let value = body()
            state = .done(value)
            return value
        }
    }
}
