/// The hang-watch slots of one process: each watched thread or lane registers once, then opens a
/// ``HangWatchScope`` around each unit of work, with a deadline. A watcher (the app's hang monitor
/// on the main-thread watchdog's kqueue, task 067) reports a slot whose scope is open past its deadline.
///
/// This is Chrome's `base::HangWatcher` model (base/threading/hang_watcher.h): `RegisterThread` per
/// thread type, `WatchHangsInScope` as a nesting RAII scope (default deadline 10 s), the deadline and
/// its flags packed in one atomic word (`HangWatchDeadline`), and `InvalidateActiveExpectations()` for
/// a wait the thread is allowed to make. cmux differs in one rule: its watcher parks while no scope
/// opens, so an idle process has no hang-watch wakeup (p09-observability.md section 3E).
///
/// Stub (task 000): the signatures are frozen; registering and scoping record nothing until task 066
/// fills the slot table (opening and closing a scope will be two atomic stores and no system call).
///
/// ```swift
/// let lane = runtime.hangWatch.registerLane("terminal-output")
/// runtime.hangWatch.watch(lane, deadline: .seconds(1)) { feed(chunk) }
/// ```
public final class HangWatch: Sendable {
    /// An empty slot table.
    public init() {}

    /// Registers the calling thread, which runs work of kind `kind` (Chrome's `HangWatcher::ThreadType`).
    ///
    /// - Parameters:
    ///   - kind: What the thread runs (it picks the default deadline and the report's grouping).
    ///   - name: The thread's name in hang reports (a catalog string, never a person's text).
    /// - Returns: The slot; pass it to ``watch(_:deadline:)`` and ``unregister(_:)``.
    public func registerThread(_ kind: ThreadKind, name: StaticString) -> Registration {
        Registration(slot: 0, generation: 0) // Task 066.
    }

    /// Registers a serial lane (a dispatch queue or a lane of `BackgroundWork`): its jobs may run on any
    /// thread, so each scope stores the thread that runs it (`mach_thread_self()`) for the stack sample.
    ///
    /// - Parameter name: The lane's name in hang reports.
    /// - Returns: The slot.
    public func registerLane(_ name: StaticString) -> Registration {
        Registration(slot: 0, generation: 0) // Task 066.
    }

    /// Frees a slot (the thread ends or the lane closes); its open scopes are forgotten.
    public func unregister(_ registration: Registration) {
        // Task 066.
    }

    /// Opens a scope on `registration`'s slot: the slot hangs if the scope is still open after
    /// `deadline`. Scopes nest; the innermost deadline applies until it closes.
    ///
    /// - Returns: The scope; it closes when it goes away (end it at the end of the unit of work).
    public func watch(_ registration: Registration, deadline: Duration = .seconds(10)) -> HangWatchScope {
        HangWatchScope(registration: registration, previousDeadline: 0) // Task 066.
    }

    /// Runs `body` inside a scope on `registration`'s slot.
    ///
    /// - Returns: What `body` returns.
    public func watch<T>(_ registration: Registration, deadline: Duration = .seconds(10),
                         _ body: () throws -> T) rethrows -> T {
        let scope = watch(registration, deadline: deadline)
        let result = try body() // a throw ends `scope` as it unwinds
        scope.close()
        return result
    }

    /// Cancels the open scopes of the calling thread's slots, before a wait the thread is allowed to
    /// make: a nested run loop, a modal panel, a network or process wait (Chrome's
    /// `InvalidateActiveExpectations()`). The next scope that opens watches again.
    public func invalidateActive() {
        // Task 066.
    }
}

extension HangWatch {
    /// What a registered thread runs. The raw values are shared with the Rust `cmux-hang-watch` crate.
    public enum ThreadKind: UInt8, Sendable, CaseIterable {
        /// The main thread.
        case main = 1
        /// A socket or PTY reader or writer (bounded I/O only; the wait itself stays outside the scope).
        case io = 2
        /// A serial work lane (``registerLane(_:)`` registers these).
        case lane = 3
        /// A renderer thread (Ghostty's, the remote view's Metal renderer).
        case renderer = 4
        /// A thread-pool worker (a tokio worker, a `BackgroundWork` thread).
        case pool = 5
        /// A control-socket handler.
        case control = 6
    }

    /// A registered slot: its index in the slot table and the generation that tells a reused slot apart.
    public struct Registration: Sendable, Hashable {
        /// The slot's index.
        public let slot: UInt32
        /// The slot's generation when it was registered.
        public let generation: UInt32
    }
}

/// One open hang-watch scope (Chrome's `WatchHangsInScope`). Not copyable: it closes exactly once,
/// with ``close()`` or when it goes away, and restores the enclosing scope's deadline.
public struct HangWatchScope: ~Copyable, Sendable {
    /// The slot the scope watches.
    let registration: HangWatch.Registration
    /// The packed deadline the scope replaced (the enclosing scope's), restored at close.
    let previousDeadline: UInt64

    /// Closes the scope now (before the end of the code block that holds it).
    public consuming func close() {}

    deinit {
        // Task 066: restore `previousDeadline` in the slot.
    }
}
