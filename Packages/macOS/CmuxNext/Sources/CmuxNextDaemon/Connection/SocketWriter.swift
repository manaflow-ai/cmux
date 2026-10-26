import CmuxNextIPC
import Dispatch
import Foundation

/// Writes to a connected daemon socket without ever blocking the caller
/// (architecture.md 5a). Callers are actors on the cooperative pool; a
/// blocking `write` there parked a pool thread for as long as the daemon did
/// not read its socket (a Unix socket buffers only a few KB, so a burst of
/// commands to a busy daemon filled it).
///
/// The owner of CmuxNextIPC's ``FrameWriter`` over the socket (p05-ipc-055):
/// writes append to the writer's priority FIFOs and return at once; its private
/// serial queue drains them, input before control before bulk, call order within
/// a priority. Only that queue's thread ever waits on the socket. Past `limit`
/// queued bytes a write fails with ``FrameWriter/Failure/backlog(queued:)``.
final class SocketWriter: Sendable {
    private let writer: FrameWriter

    /// - Parameter qos: The drain queue's class, chosen by the owner from what the connection
    ///   carries (``DaemonWireStats/Role/writerQoS``).
    init(fd: Int32, label: String, qos: DispatchQoS, limit: Int = FrameWriter.defaultLimit) {
        writer = FrameWriter(sink: SocketFrameSink(fd: fd), label: label, qos: qos, limit: limit)
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

    /// Stops writing; queued bytes are dropped. The owner shuts the
    /// descriptor down, which also ends a write in progress.
    func close() {
        writer.close()
    }
}

/// Why `SocketWriter.write` failed: the frame writer's failure.
typealias SocketWriteFailure = FrameWriter.Failure

extension DaemonWireStats.Role {
    /// The class of this connection's ``SocketWriter`` queue, by what it carries
    /// (threading-model.md, QoS table). Only the connections that carry typed keys run at
    /// user-interactive, so a bulk loopback forward never shares the class of a keystroke.
    var writerQoS: DispatchQoS {
        switch self {
        case .control, .terminalAttach:
            // qos-allow: key echo path: typed keys reach the daemon on these connections and the echo frame waits for them
            .userInteractive
        case .pageRelay, .agentSessionAttach, .journalRead, .sessionEnding, .shutdown:
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
}
