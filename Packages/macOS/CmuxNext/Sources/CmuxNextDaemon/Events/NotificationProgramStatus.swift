import Foundation

/// Why the daemon posted a program status notification
/// (`notification-program-status-v1`): an OSC 7501 record entered `blocked`
/// or `error`. The daemon still sends an English title and body; the app
/// builds the body in the user's language from this. `msg` is the program's
/// message, already stripped of control and invisible formatting characters
/// by the daemon: plain display text, never a link or a command.
public struct NotificationProgramStatus: Sendable, Hashable, Decodable {
    public enum State: String, Sendable, Hashable, Decodable {
        case blocked, error
    }

    /// What a `blocked` program waits for.
    public enum Kind: String, Sendable, Hashable, Decodable {
        case permission, question, auth
    }

    public var state: State
    public var kind: Kind?
    public var msg: String?

    public init(state: State, kind: Kind? = nil, msg: String? = nil) {
        self.state = state
        self.kind = kind
        self.msg = msg
    }

    enum CodingKeys: String, CodingKey {
        case state, kind, msg
    }

    /// Throws on an unknown `state` (the notification then keeps the daemon's
    /// body); an unknown `kind` reads as no kind.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        kind = try? c.decodeIfPresent(Kind.self, forKey: .kind)
        msg = try? c.decodeIfPresent(String.self, forKey: .msg)
    }
}
