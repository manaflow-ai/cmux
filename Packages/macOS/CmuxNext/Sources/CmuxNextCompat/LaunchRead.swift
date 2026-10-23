import Foundation

/// One saved file the launch's first window draws (the launch snapshot, the saved sidebars), read
/// and decoded on a background task begun at the top of `main`, so the read overlaps AppKit's
/// start instead of holding the first window frame (#17587).
///
/// The main thread takes the value when it builds the window. The file is read once, never twice:
/// - the background read finished: ``take()`` returns its value at once;
/// - the background read is running: ``take()`` waits for the rest of it. The reader holds an
///   `os_unfair_lock` for the whole read, so the waiting thread donates its priority to it, and
///   waiting for the rest of a read is always shorter than a second read from zero;
/// - the background task has not begun: ``take()`` reads on the taking thread, and the task, when
///   it runs, finds the value taken and reads nothing.
///
/// When the main thread waited or read, `readOnMain` hears `launch_read_on_main.<name>`, the mark
/// the startup bench's launch guard fails on (`scripts/cmux-next/bench-startup.py --launch-guard`).
///
/// ```swift
/// let sidebar = LaunchRead("sidebar_snapshot", readOnMain: { DebugTimings.markLaunch($0) }) { file.read() }
/// // ... later, building the first window:
/// let document = sidebar.take()
/// ```
public final class LaunchRead<Value: Sendable>: Sendable {
    private enum State {
        /// Not read yet: the background task has not begun, or it is reading (and holds the lock).
        case pending
        case done(Value)
        case taken
    }

    /// The hand-off cell the reading task and ``take()`` share (the task holds it, not `self`).
    private final class Slot: Sendable {
        // Held by the reader for its whole read, so a synchronous `take` inside a window build waits for
        // the rest of it with priority donation (os_unfair_lock records its owner): an actor cannot serve
        // a synchronous caller, and a second read from zero is always slower than that wait.
        let state = Mutex(State.pending)
    }

    private let slot: Slot
    private let name: String
    private let read: @Sendable () -> Value
    private let readOnMain: @Sendable (String) -> Void
    private let reading: Task<Void, Never>

    /// Starts `read` now, on a background task.
    /// - Parameters:
    ///   - name: The file's name in the `launch_read_on_main.<name>` mark.
    ///   - readOnMain: Receives that mark when ``take()`` waits for the read or reads on the main thread.
    ///   - read: Reads and decodes the value. It runs once: on the background task, or on the taking
    ///     thread when that task has not begun at ``take()``.
    public init(_ name: String, readOnMain: @escaping @Sendable (String) -> Void,
                read: @escaping @Sendable () -> Value) {
        self.name = name
        self.read = read
        self.readOnMain = readOnMain
        let slot = Slot()
        self.slot = slot
        // task-owner: one read per launch file, bounded by the file's own size cap
        reading = Task.detached(priority: .userInitiated) {
            slot.state.withLock { state in
                guard case .pending = state else { return }
                state = .done(read())
            }
        }
    }

    /// Returns once the background task ended (tests).
    package func backgroundReadFinished() async {
        await reading.value
    }

    /// The value the background read produced (after waiting for the rest of it when it is
    /// running), else the value read now on the caller's thread. Call once: the value is handed
    /// over, not kept; a second call reads the file again.
    // perf-hot: 1ms launch-first-window (inside the launch window's build, before its first frame, #17587)
    public func take() -> Value {
        // Busy (nil) only while the reader reads; `.some(nil)`: not read yet, or taken.
        let ready = slot.state.withLockIfAvailable { state -> Value? in
            guard case .done(let value) = state else { return nil }
            state = .taken
            return value
        }
        if let ready = ready ?? nil { return ready }
        if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
        let read = read
        return slot.state.withLock { state -> Value in
            defer { state = .taken }
            if case .done(let value) = state { return value }
            return read()
        }
    }
}
