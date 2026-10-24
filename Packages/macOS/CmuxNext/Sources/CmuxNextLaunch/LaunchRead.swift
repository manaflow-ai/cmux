import Dispatch
import Foundation

/// One saved file the launch draws or keeps (the launch snapshot, the new chats' unsent drafts, the
/// chats' composer states, the Home cache and the Home list's last state), read and decoded on its
/// own background thread begun at the top of `main`, so the read overlaps AppKit's start instead of
/// holding the first window frame (#17587). Use it for a value the main thread needs whole when it
/// builds what the launch shows; a set of per-pane images, each wanted by one pane that can draw
/// without it for a frame, is a ``SavedFrameDirectory`` (never waited for).
///
/// The read runs as the one block of a serial dispatch queue of its own: a blocking file read and
/// decode belong on a thread that may block, not on the Swift cooperative pool the daemon connect
/// needs at the same moment. No lock is held while it reads; a lock guards only the hand-off of the
/// value (``LaunchReadSlot``). The main thread takes the value when it builds the window, and the
/// file is read once:
/// - the read finished: ``take()`` returns its value at once;
/// - the read is queued or running: ``take()`` waits for that block to end (an empty `sync` on its
///   serial queue, which raises the queue to the waiting thread's QoS), never reads again.
///
/// When the main thread waited, `readOnMain` hears `launch_read_on_main.<name>`, the mark the
/// startup bench's launch guard fails on (`scripts/cmux-next/bench-startup.py --launch-guard`).
///
/// ```swift
/// let drafts = LaunchRead("unsent_drafts", readOnMain: { DebugTimings.markLaunch($0) }) { AgentUnsentDrafts.read(file) }
/// // ... later, making the agent tab store:
/// let saved = drafts.take()
/// ```
public nonisolated final class LaunchRead<Value: Sendable>: Sendable {
    private let slot: LaunchReadSlot<Value>
    private let name: String
    private let read: @Sendable () -> Value
    private let readOnMain: @Sendable (String) -> Void
    /// Runs the one read. A dispatch queue, not a `Task`: the read blocks on I/O, and a synchronous
    /// `take` can wait for exactly this read with QoS donation; an actor cannot serve that caller.
    private let queue: DispatchQueue

    /// Starts `read` now, on a background thread.
    /// - Parameters:
    ///   - name: The file's name in the `launch_read_on_main.<name>` mark.
    ///   - readOnMain: Receives that mark when ``take()`` waits for the read on the main thread.
    ///   - read: Reads and decodes the value, once, off the main thread.
    public init(_ name: String, readOnMain: @escaping @Sendable (String) -> Void,
                read: @escaping @Sendable () -> Value) {
        self.name = name
        self.read = read
        self.readOnMain = readOnMain
        let slot = LaunchReadSlot<Value>()
        self.slot = slot
        // concurrency-allow: a serial queue of its own for one blocking launch-file read (work delivery, not a lock on state); `take` waits for its one block
        queue = DispatchQueue(label: "com.cmuxterm.launch-read.\(name)", qos: .userInitiated)
        queue.async { slot.finish(read()) }
    }

    /// Returns once the background read ended (tests).
    package func backgroundReadFinished() async {
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            queue.async { finished.resume() }
        }
    }

    /// Runs `body` with the value once the read finished, on the read's queue, unless ``take()``
    /// took the value first. The launch orders other launch work by it (the launch snapshot's
    /// shown panes decode their last frames first).
    /// - Parameter body: Receives a copy of the value; the value stays for ``take()``. Keep it
    ///   short: a ``take()`` that waits for the read waits for it too (the queue is serial).
    public func whenRead(_ body: @escaping @Sendable (Value) -> Void) {
        let slot = slot
        // After the read: the queue is serial.
        queue.async {
            if let value = slot.peek() { body(value) }
        }
    }

    /// The value the background read produced, after waiting for the rest of that read when it has
    /// not finished. Call once: the value is handed over, not kept; a second call reads the file
    /// again, on the caller's thread.
    // perf-hot: 1ms launch-first-window (inside the launch window's build, before its first frame, #17587)
    public func take() -> Value {
        switch slot.claim() {
        case .value(let value):
            return value
        case .wait:
            if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
            // concurrency-allow: waits for the one-shot read's block to end (not a lock on state); dispatch_sync on its serial queue donates the caller's QoS to it
            queue.sync {}
            return slot.takeAfterWait() ?? read()
        case .taken:
            if Thread.isMainThread { readOnMain("launch_read_on_main.\(name)") }
            return read()
        }
    }
}
