public import Foundation

/// One event on an attached remote PTY stream, delivered in order on the
/// queue supplied to ``RemotePTYBridgeRPCClient/attachBridgePTY(sessionID:attachmentID:cols:rows:command:requireExisting:queue:onEvent:)``.
public enum RemotePTYBridgeEvent: Sendable {
    /// The attachment finished its handshake and will start delivering output.
    case ready
    /// A chunk of PTY output bytes.
    case data(Data)
    /// The remote PTY exited; no further events follow.
    case exit
    /// The attachment failed; the payload is the daemon's error text.
    case error(String)
}
