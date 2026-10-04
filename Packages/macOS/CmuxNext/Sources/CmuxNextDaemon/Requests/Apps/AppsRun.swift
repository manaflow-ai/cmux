import Foundation

/// `apps-run`: one catalog op of an app, answered by the app's QuickJS host
/// or its server (cmux-tui-core `server/apps.rs`, `apps/runs.rs`). The
/// answer is the op's result. A keyed run runs once: a retry with the same
/// key gets the stored answer, so each user intent sends a new key. Any
/// `apps-` request also subscribes the connection to the app events
/// (`apps-server-event`, ``AppServerEvent``).
public struct AppsRunRequest: DaemonRequest {
    public typealias Response = AppsRunResult
    public static let command = "apps-run"

    /// The request origin. `user` needs the verified cmux app connection.
    public enum Origin: String, Encodable, Sendable {
        case user
        case script
    }

    public var app: String
    public var op: String
    public var args: JSONValue
    public var idempotencyKey: String?
    public var origin: Origin

    public init(app: String, op: String, args: JSONValue, idempotencyKey: String?, origin: Origin) {
        self.app = app
        self.op = op
        self.args = args
        self.idempotencyKey = idempotencyKey
        self.origin = origin
    }
}

/// An `apps-run` answer: the daemon wraps every op result as `{value}`
/// (QuickJS host and server alike).
public struct AppsRunResult: Decodable, Sendable, Equatable {
    public let value: JSONValue

    public init(value: JSONValue) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case value }
        let container = try decoder.container(keyedBy: Keys.self)
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
    }
}

/// `apps-terminal-links`: every open terminal connector link and its local
/// socket (`{links: [{channel, app, id, target, socket}]}`). Read-only; like
/// any `apps-` request it subscribes the connection to app events.
public struct AppsTerminalLinksRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-terminal-links"

    public init() {}
}
