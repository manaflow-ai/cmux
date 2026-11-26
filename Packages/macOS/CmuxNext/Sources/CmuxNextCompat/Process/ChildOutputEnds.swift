public import Foundation

/// Closes this app's ends of a child's pipes once the child is gone, for every owner that reads a
/// child's output with a `readabilityHandler`.
///
/// A handler cleared only at end of file keeps its read end (and its `FileHandle`, retained by the
/// handler's dispatch source) open as long as any process holds the write end: a grandchild the
/// child left running (an ssh ControlPersist master, a backgrounded helper, an orphaned `perl`)
/// inherits it, so the end of file never comes and each restart of the child leaves one more pipe
/// open in the app. NIGHTLY held about 2,000 pipes when it hung 391 s in a pipe write
/// (cmuxterm-hq#8747). A grandchild still writing then gets EPIPE instead of filling a pipe nobody
/// reads.
public struct ChildOutputEnds {
    public init() {}
    /// How long after the child's exit its readers still drain what it wrote before the read ends
    /// close: the bytes are already in the pipe at exit, so a reader that is not stalled takes
    /// milliseconds.
    public static let drainGrace: Duration = .seconds(2)

    /// Call from the child's `terminationHandler`: after ``drainGrace`` each handle's reader stops
    /// and the handle closes (an end already closed stays closed), then `closed` runs (an owner ends
    /// the streams its readers would have ended at end of file). `writing` (a stdin write end the
    /// parent still holds) closes at once: no one reads it any more.
    public static func closeAfterExit(reading: [FileHandle], writing: [FileHandle] = [], grace: Duration = drainGrace,
                                      closed: (@Sendable () -> Void)? = nil) {
        for handle in writing { try? handle.close() }
        let (seconds, attoseconds) = grace.components
        let nanos = max(0, Int(seconds) * 1_000_000_000 + Int(attoseconds / 1_000_000_000))
        // The shared utility queue: the close is a few syscalls and holds no state of its own.
        // concurrency-allow: a one-shot deadline per exited child on the shared utility queue, never the main thread;
        // CmuxNextCompat sits below CmuxNextWakeups, so DemandTimer is out of reach here
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .nanoseconds(nanos)) {
            closeNow(reading: reading)
            closed?()
        }
    }

    /// Stops each reader and closes every end now: a `run()` that threw (no termination handler
    /// will come, and the parent still holds the write ends, so no end of file either), or a stop.
    public static func closeNow(reading: [FileHandle], writing: [FileHandle] = []) {
        for handle in reading {
            handle.readabilityHandler = nil
            try? handle.close()
        }
        for handle in writing { try? handle.close() }
    }

    /// ``closeNow(reading:writing:)`` for every pipe of a `run()` that threw: both ends of each.
    public static func closeNow(pipes: [Pipe]) {
        closeNow(reading: pipes.map(\.fileHandleForReading), writing: pipes.map(\.fileHandleForWriting))
    }
}
