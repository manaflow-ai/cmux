import Foundation

/// One saved file the launch's first window draws (the launch snapshot, the saved sidebars), read
/// and decoded on a background task begun at the top of `main`, so the read overlaps AppKit's
/// start instead of holding the first window frame (#17587).
///
/// The main thread takes the value when it builds the window. A read still running then is not
/// waited for (that would block the main thread on a lower-priority task): the taking thread reads
/// the value itself, as it did before there was a prefetch, and the late background result is
/// dropped. So a launch is never slower than reading on the main thread. Such a read on the main
/// thread calls `readOnMain` with `launch_read_on_main.<name>`, the mark the startup bench's
/// launch guard fails on (`scripts/cmux-next/bench-startup.py --launch-guard`).
///
/// ```swift
/// let sidebar = LaunchRead("sidebar_snapshot", readOnMain: { DebugTimings.markLaunch($0) }) { file.read() }
/// // ... later, building the first window:
/// let document = sidebar.take()
/// ```
public final class LaunchRead<Value: Sendable>: Sendable {
    private enum State {
        case reading
        case done(Value)
        case taken
    }

    /// The hand-off cell the reading task and ``take()`` share (the task holds it, not `self`).
    private final class Slot: Sendable {
        // One-shot hand-off between the reading task and the single synchronous `take()`: `take` runs
        // inside a window build and must never wait on the reader, so an actor (an await) cannot serve it.
        let state = Mutex(State.reading)
    }

    private let slot: Slot
    private let name: String
    private let read: @Sendable () -> Value
    private let readOnMain: @Sendable (String) -> Void
    private let reading: Task<Void, Never>

    /// Starts `read` now, on a background task.
    /// - Parameters:
    ///   - name: The file's name in the `launch_read_on_main.<name>` mark.
    ///   - readOnMain: Receives that mark when ``take()`` reads the value on the main thread.
    ///   - read: Reads and decodes the value; it runs once in the background and, when the
    ///     background read has not finished at ``take()``, once more on the taking thread.
    public init(_ name: String, readOnMain: @escaping @Sendable (String) -> Void,
                read: @escaping @Sendable () -> Value) {
        self.name = name
        self.read = read
        self.readOnMain = readOnMain
        let slot = Slot()
        self.slot = slot
        // task-owner: one read per launch file, bounded by the file's own size cap
        reading = Task.detached(priority: .userInitiated) {
            let value = read()
            slot.state.withLock { state in
                if case .reading = state { state = .done(value) }
            }
        }
    }

    /// Returns once the background read finished (tests).
    package func backgroundReadFinished() async {
        await reading.value
    }

    /// The value the background read produced, else the value read now on the caller's thread.
    /// Call once: the value is handed over, not kept.
    public func take() -> Value {
        let ready = slot.state.withLock { state -> Value? in
            defer { state = .taken }
            if case .done(let value) = state { return value }
            return nil
        }
        if let ready { return ready }
        if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
        return read()
    }
}
