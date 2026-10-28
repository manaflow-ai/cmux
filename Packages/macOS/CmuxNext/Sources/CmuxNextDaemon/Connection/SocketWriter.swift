import CmuxNextIPC
import CmuxNextTrace
import Dispatch
import Foundation

/// Writes to a connected daemon socket without ever blocking the caller
/// (architecture.md 5a). Callers are actors on the cooperative pool; a
/// blocking `write` there parked a pool thread for as long as the daemon did
/// not read its socket (a Unix socket buffers only a few KB, so a burst of
/// commands to a busy daemon filled it).
///
/// The owner of CmuxNextIPC's ``FrameWriter`` over the socket:
/// a write from off the main thread to an idle writer (nothing of its own or a
/// higher priority waiting, no send in flight) goes to the socket on the caller's
/// thread with a send that never waits, and the drain queue is not woken
/// (Mojo's `ChannelPosix::Write`). Every other write, and every write
/// from the main thread, appends to the writer's priority FIFOs and returns at
/// once; its private serial queue drains them, input before control before bulk,
/// call order within a priority. Only that queue's thread ever waits on the
/// socket. Past `limit` queued bytes a write fails with
/// ``FrameWriter/Failure/backlog(queued:)``.
///
/// Each drain step (one send) is one `daemon.write` hang scope of ``writeHangDeadline``; a write waiting in
/// the FIFOs is in none, and so is an inline send: it never waits for the socket, so it cannot hang. Chrome
/// watches each IO-thread task the same way (base/threading/hang_watcher.h, `WatchHangsInScope` per task of
/// `ThreadControllerWithMessagePumpImpl`).
final class SocketWriter: Sendable {
    /// One drain step's budget: a jank past it, a hang dump 2 s later. A step sends at most 64 KiB or one
    /// bulk chunk, so a send stuck this long means the daemon stopped reading its socket.
    static let writeHangDeadline: Duration = .seconds(2)

    private let writer: FrameWriter
    /// Watches each drain step on the drain queue, never a write waiting its turn; nil watches nothing.
    private let hangWatched: HangWatchedLane?

    /// - Parameter qos: The drain queue's class, chosen by the owner from what the connection
    ///   carries (``DaemonWireStats/Role/writerQoS``).
    /// - Parameter target: A serial queue the drain runs on (its target), nil for none. A terminal attach
    ///   passes its input lane's queue: a key written from that queue is sent to the socket on the same
    ///   thread, after the lane's turn, with no second thread hop.
    /// - Parameter hangs: Watches each drain step as the `daemon.write` lane; nil watches nothing.
    init(fd: Int32, label: String, qos: DispatchQoS, target: DispatchQueue? = nil, limit: Int = FrameWriter.defaultLimit,
         hangs: (any HangWatchScoping)? = nil) {
        let watched = hangs.map { HangWatchedLane("daemon.write", deadline: Self.writeHangDeadline, on: $0) }
        hangWatched = watched
        let runStep = watched.map { lane -> FrameWriter.StepRunner in { step in lane.run(step) } }
        writer = FrameWriter(sink: SocketFrameSink(fd: fd), label: label, qos: qos, target: target, limit: limit,
                             runStep: runStep)
    }

    deinit {
        hangWatched?.unregister()
    }

    /// Appends `bytes` at control priority, after everything written before at
    /// that priority: the JSON lines of requests and stream lines keep one FIFO.
    /// Returns why it failed when the socket failed, closed, or the backlog passed
    /// the limit.
    func write(_ bytes: Data) -> SocketWriteFailure? {
        writer.enqueue(bytes, priority: .control)
    }

    /// Appends one message at `priority`, ahead of every lower priority and after
    /// every earlier message of its own; `fds` ride its first byte and the writer
    /// owns them from this call on (``FrameWriter/enqueue(_:priority:fds:)``).
    func write(_ bytes: Data, priority: MethodPriority, fds: [Int32] = []) -> SocketWriteFailure? {
        writer.enqueue(bytes, priority: priority, fds: fds)
    }

    /// The drain queue's QoS (tests).
    var queueQoS: DispatchQoS { writer.queueQoS }

    /// Bytes waiting for the socket (diagnostics, tests).
    var queuedBytes: Int { writer.queuedBytes }

    /// Times a write woke the drain queue (``FrameWriter/queueHops``; tests).
    var queueHops: Int { writer.queueHops }

    /// Stops writing; queued bytes are dropped. The owner shuts the
    /// descriptor down, which also ends a write in progress.
    func close() {
        writer.close()
    }
}

/// Why `SocketWriter.write` failed: the frame writer's failure.
typealias SocketWriteFailure = FrameWriter.Failure

extension DaemonWireStats.Role {
    /// The class of this connection's ``SocketWriter`` queue and of its reader thread, by what it carries
    /// (threading-model.md, QoS table). Both directions serve the same waiter, so they share one class.
    /// Only the terminal attach connection, which carries most typed keys (`TerminalAttachment.enqueueInput`)
    /// and their echo, runs at user-interactive: control commands, replies and events (automation, sidebar
    /// churn) and bulk loopback forwards never share a keystroke's class. Two key paths still use `control`
    /// and so run at user-initiated: `send {terminal_id}` from `CreatingTerminalInput` before a new split is
    /// attached (until p04-input-058 buffers it until attach), and `send-key` for a TUI's Command chords from
    /// `TerminalHooks`. Chromium maps its default thread type to user-initiated and keeps user-interactive
    /// for the threads input and display wait on (base/threading/platform_thread_apple.mm).
    var writerQoS: DispatchQoS {
        switch self {
        case .terminalAttach:
            // qos-allow: key echo path: typed keys reach the daemon on this connection and the echo frame waits for its bytes
            .userInteractive
        case .control, .pageRelay, .agentSessionAttach, .journalRead, .sessionEnding, .shutdown:
            // userBlocking: a person waits now for the result of a click, an open or quit.
            .userInitiated
        case .loopbackForward:
            // Bulk forwarded page bytes: one class below the roles a person waits for, so a large stream never
            // crowds them out (not the userVisible lane mapping, which is user-initiated; threading-model.md).
            .default
        case .socketProbe:
            // bestEffort: a liveness probe nobody watches.
            .utility
        }
    }

    /// The class of this connection's reader thread (`cmux-tui reader <path>`): the writer's, as a thread QoS.
    var readerQoS: QualityOfService {
        switch writerQoS.qosClass {
        case .userInteractive: .userInteractive
        case .userInitiated: .userInitiated
        case .utility: .utility
        case .background: .background
        default: .default
        }
    }
}
