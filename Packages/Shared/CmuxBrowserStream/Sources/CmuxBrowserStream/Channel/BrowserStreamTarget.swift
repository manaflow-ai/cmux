public import CmuxMobileWire

/// What a stream channel shows: a Mac browser tab (`browser`, C2) or a booted
/// iOS simulator of the Mac (`simulator`, C14). Both carry the same rd/rb
/// records; only the channel kind and the id parameter differ.
public enum BrowserStreamTarget: Hashable, Sendable {
    /// A browser tab record id (`tab_…`).
    case tab(String)
    /// A simulator UDID.
    case simulator(String)

    public var kind: ChannelKind {
        switch self {
        case .tab: .browser
        case .simulator: .simulator
        }
    }

    public var id: String {
        switch self {
        case .tab(let id), .simulator(let id): id
        }
    }

    /// The `channel.open` params key that carries `id`.
    public var parameterName: String {
        switch self {
        case .tab: "tab"
        case .simulator: "udid"
        }
    }

    /// Link stream name (informational).
    public var stream: String { "\(kind.rawValue)/\(id)" }

    /// Whether `id` is well formed for this target.
    public var isValid: Bool {
        switch self {
        case .tab(let id):
            return id.hasPrefix("tab_") && id.count <= 128
        case .simulator(let udid):
            return udid.count == 36 && udid.allSatisfy { $0.isHexDigit || $0 == "-" }
        }
    }
}
