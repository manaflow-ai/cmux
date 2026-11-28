import Foundation

/// Arms (`on: true`) or disarms one hosted terminal's one-shot command-finish watch
/// (`terminal-notify-when-done-v1`, Notify When Command Finishes): the next command its shell
/// finishes posts one terminal notification, then the watch disarms. Name it by `surface` (a PTY
/// tab showing it) or `terminal` (its public `term_` id), exactly one.
public struct SetTerminalNotifyWhenDoneRequest: DaemonRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The terminal's public id (`term_…`).
        public var terminal: String
        public var on: Bool
    }

    public enum Target: Sendable, Hashable {
        case surface(SurfaceID)
        case terminal(ResourceID)
    }

    public static let command = "set-terminal-notify-when-done"
    public static let requiredCapability: String? = DaemonCapability.terminalNotifyWhenDone.rawValue
    public var target: Target
    public var on: Bool

    public init(_ target: Target, on: Bool) {
        self.target = target
        self.on = on
    }

    enum CodingKeys: String, CodingKey { case surface, terminal, on }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch target {
        case .surface(let surface): try c.encode(surface, forKey: .surface)
        case .terminal(let terminal): try c.encode(terminal.rawValue, forKey: .terminal)
        }
        try c.encode(on, forKey: .on)
    }
}
