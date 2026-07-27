public import Foundation

/// One event on an attached daemon PTY, delivered in order on the queue
/// supplied to
/// ``RemoteDaemonRPCClient/attachPTY(sessionID:attachmentID:cols:rows:command:requireExisting:queue:onEvent:)``
/// (faithful lift of the client's nested `PTYEvent`; case payloads are
/// wire-derived, do not change them).
public enum RemoteDaemonPTYEvent: Sendable {
    /// The attachment finished its handshake (`pty.ready`).
    case ready
    /// A chunk of PTY output bytes (`pty.data`).
    case data(Data)
    /// Cumulative ack for sequenced PTY input (`pty.input_ack`).
    case inputAck(seq: UInt64)
    /// The remote PTY exited; no further events follow (`pty.exit`).
    case exit
    /// The attachment failed; payload is the daemon's error text
    /// (`pty.error`).
    case error(String)
}
