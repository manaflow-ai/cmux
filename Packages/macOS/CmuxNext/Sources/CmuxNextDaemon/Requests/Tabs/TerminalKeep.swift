import Foundation

/// Marks one hosted terminal kept (`keep: true`) or reapable
/// (`terminal-reap-v1`). A kept terminal outlives its last tab; an unkept
/// one ends after the daemon's reap grace period (default 30 s) with no tab.
/// Name it by `surface` (a PTY tab showing it) or `terminal_id` (host id or
/// public `term_` id), exactly one.
public struct SetTerminalKeepRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var terminalID: TerminalID
        public var keep: Bool

        enum CodingKeys: String, CodingKey {
            case keep
            case terminalID = "terminal_id"
        }
    }

    public enum Target: Sendable, Hashable {
        case surface(SurfaceID)
        case terminal(TerminalID)
    }

    public static let command = "set-terminal-keep"
    public var target: Target
    public var keep: Bool

    public init(_ target: Target, keep: Bool) {
        self.target = target
        self.keep = keep
    }

    enum CodingKeys: String, CodingKey { case surface, terminalID, keep }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .surface(let surface): try c.encode(surface, forKey: .surface)
        case .terminal(let terminal): try c.encode(terminal, forKey: .terminalID)
        }
        try c.encode(keep, forKey: .keep)
    }
}
