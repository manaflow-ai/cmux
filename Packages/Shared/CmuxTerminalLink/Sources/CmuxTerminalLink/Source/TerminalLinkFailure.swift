/// Why a terminal stream ended, for the screen's notice. The iOS target
/// localizes it; `defaultText` is the English fallback.
public enum TerminalLinkFailure: Hashable, Sendable {
    /// No session with the Mac (carrier down, Mac asleep or not running cmux).
    case unreachable
    /// The Mac refused this device (`auth.*`).
    case unauthorized(code: String)
    /// The terminal is not on that Mac any more.
    case notFound
    case exited
    case kicked(byDisplayName: String)
    case revoked
    /// The Mac ended the attach with another code, or refused it.
    case ended(code: String)
    /// The link kept dropping before a screen arrived.
    case unstable

    public init(closeCode code: String?) {
        switch code {
        case "terminal.exited": self = .exited
        case "terminal.not_found": self = .notFound
        case "auth.revoked": self = .revoked
        case let code? where code.hasPrefix("auth."): self = .unauthorized(code: code)
        case let code?: self = .ended(code: code)
        case nil: self = .ended(code: "channel.closed")
        }
    }

    public var defaultText: String {
        switch self {
        case .unreachable: "No connection to this Mac."
        case .unauthorized: "This Mac did not accept this device."
        case .notFound: "This terminal is no longer on the Mac."
        case .exited: "The terminal exited."
        case .kicked(let name): "Disconnected by \(name)."
        case .revoked: "This device was removed from the Mac."
        case .ended: "The Mac ended this terminal session."
        case .unstable: "The connection kept dropping."
        }
    }
}
