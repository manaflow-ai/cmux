public import Foundation

/// One event on a subscribed daemon proxy stream, delivered in order on the
/// queue supplied to
/// ``RemoteDaemonRPCClient/attachStream(streamID:queue:onEvent:)``
/// (faithful lift of the client's nested `StreamEvent`; case payloads are
/// wire-derived, do not change them).
public enum RemoteDaemonStreamEvent: Sendable {
    /// A chunk of stream bytes (`proxy.stream.data`).
    case data(Data)
    /// The stream ended; payload is any final bytes (`proxy.stream.eof`).
    case eof(Data)
    /// The stream failed; payload is the daemon's error text
    /// (`proxy.stream.error`).
    case error(String)
}
