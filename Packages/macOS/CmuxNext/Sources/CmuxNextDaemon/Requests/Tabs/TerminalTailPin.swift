import Foundation

/// Pins (`pinned: true`) or unpins one hosted terminal's last output line under its workspace in
/// the sidebar (`terminal-tail-pin-v1`, Show Last Line in Sidebar). Name it by `surface` (a PTY
/// tab showing it) or `terminal` (its public `term_` id), exactly one; a pinned terminal with no
/// tab left still unpins by its id.
public struct SetTerminalTailPinRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The terminal's public id (`term_…`).
        public var terminal: String
        public var pinned: Bool
    }

    public enum Target: Sendable, Hashable {
        case surface(SurfaceID)
        case terminal(ResourceID)
    }

    public static let command = "set-terminal-tail-pin"
    public static let requiredCapability: String? = DaemonCapability.terminalTailPin.rawValue
    public var target: Target
    public var pinned: Bool

    public init(_ target: Target, pinned: Bool) {
        self.target = target
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey { case surface, terminal, pinned }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .surface(let surface): try c.encode(surface, forKey: .surface)
        case .terminal(let terminal): try c.encode(terminal.rawValue, forKey: .terminal)
        }
        try c.encode(pinned, forKey: .pinned)
    }
}
