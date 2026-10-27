import CmuxNextIPC
import Foundation

/// Outbound frames that carry no request (p05-ipc-096): a terminal stream's INPUT. Request frames go through
/// ``LineTransport/submit(_:deadline:framed:_:)``, which registers their waiter.
extension LineTransport {
    /// Writes one whole frame at `priority`: after every earlier message of that priority, ahead of every lower
    /// one (``SocketWriter/write(_:priority:fds:)``). On a non-main thread with nothing of equal or higher
    /// priority waiting, the writer sends it on the calling thread (p05-ipc-140); otherwise its drain queue does.
    /// - Returns: nil, or why the frame was not written: the connection closed, or its writer refused it.
    func sendFrame(_ frame: Data, priority: MethodPriority) -> SocketWriteFailure? {
        guard !isClosed else { return .closed }
        if let failure = writer.write(frame, priority: priority) { return failure }
        recorder?.lineWritten(bytes: frame.count)
        return nil
    }
}
