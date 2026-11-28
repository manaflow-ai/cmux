public import Foundation

/// What a forwarded stream delivers, in order.
public enum LoopbackStreamEvent: Sendable, Equatable {
    /// Bytes from the target. Call `consumed(_:)` once they are written on,
    /// so the daemon may send more.
    case data(Data)
    /// The target ended its side (half close). More events may follow.
    case eof
    /// The stream is over; `error` is nil after a clean close of both sides.
    case closed(error: LoopbackStreamError?)
}

/// Why a forwarded stream ended early.
public enum LoopbackStreamError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The daemon connection dropped. Nothing falls back to this Mac.
    case connectionLost(String)
    /// The daemon ended the stream (`loopback-closed` with an error).
    case daemon(String)
    /// This client closed it.
    case closedLocally
    /// The daemon sent more than this client's window.
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .connectionLost(let detail): "connection to the machine lost: \(detail)"
        case .daemon(let reason): "the machine closed the connection (\(reason))"
        case .closedLocally: "closed"
        case .protocolViolation(let detail): "protocol violation: \(detail)"
        }
    }
}
