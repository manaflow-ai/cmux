import Foundation

/// Why a forwarded stream could not open.
public enum LoopbackForwardError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The machine's cmux-tui lacks `loopback-forward-v1` (update it).
    case unsupported
    /// The machine turned forwarding off (`server.loopback_forward`).
    case disabled
    /// Not `localhost`, `*.localhost` or a loopback address.
    case deniedHost
    /// The machine's port policy refuses this port.
    case deniedPort
    /// Nothing listens on that port of the machine.
    case refused
    case timedOut
    case limit
    /// No connection to the machine's daemon.
    case unavailable(String)
    case other(String)

    public var description: String {
        switch self {
        case .unsupported: "the machine's cmux-tui does not support loopback forwarding"
        case .disabled: "loopback forwarding is turned off on the machine"
        case .deniedHost: "only localhost and loopback addresses are forwarded"
        case .deniedPort: "the machine does not allow this port"
        case .refused: "nothing is listening on that port of the machine"
        case .timedOut: "the machine did not answer in time"
        case .limit: "too many forwarded connections"
        case .unavailable(let detail): "not connected to the machine: \(detail)"
        case .other(let detail): detail
        }
    }

    static func from(code: String?, message: String) -> LoopbackForwardError {
        switch code {
        case "loopback.not-enabled": .unsupported
        case "loopback.disabled": .disabled
        case "loopback.denied-host": .deniedHost
        case "loopback.denied-port": .deniedPort
        case "loopback.refused": .refused
        case "loopback.timeout": .timedOut
        case "loopback.limit": .limit
        default: .other(message)
        }
    }
}
