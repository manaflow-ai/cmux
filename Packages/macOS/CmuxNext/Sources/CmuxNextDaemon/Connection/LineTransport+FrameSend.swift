import CmuxNextIPC
import Foundation

/// Outbound frames that carry no request: a terminal stream's INPUT. Request frames go through
/// ``LineTransport/submit(_:deadline:framed:_:)``, which registers their waiter.
extension LineTransport {
    /// Writes one whole frame at `priority`: after every earlier message of that priority, ahead of every lower
    /// one (``SocketWriter/write(_:priority:fds:)``). On a non-main thread with nothing of equal or higher
    /// priority waiting, the writer sends it on the calling thread; otherwise its drain queue does.
    /// A frame the writer refuses on an open connection ends it (``fail(_:)``), as a refused request does in
    /// ``submit``: a later frame written behind it would reach the daemon with this one missing.
    /// - Returns: nil, or why the frame was not written: the connection closed, or its writer refused it.
    func sendFrame(_ frame: Data, priority: MethodPriority) -> SocketWriteFailure? {
        guard !isClosed else { return .closed }
        if let failure = writer.write(frame, priority: priority) {
            switch failure {
            case .closed, .peerClosed: break  // ending already; the reader reports why
            default: fail(failure.description)
            }
            return failure
        }
        recorder?.lineWritten(bytes: frame.count)
        return nil
    }
}
