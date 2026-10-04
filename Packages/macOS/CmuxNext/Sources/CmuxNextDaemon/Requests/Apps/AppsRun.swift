import Foundation

/// `apps-run`: one catalog op of an app, answered by the app's QuickJS host
/// or its server (cmux-tui-core `server/apps.rs`, `apps/runs.rs`). The
/// answer is the op's result. A keyed run runs once: a retry with the same
/// key gets the stored answer, so each user intent sends a new key. Any
/// `apps-` request also subscribes the connection to the app events
/// (`apps-server-event`, ``AppServerEvent``).
public struct AppsRunRequest: DaemonRequest {
    public typealias Response = JSONValue
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

/// An app server event as the daemon broadcasts it to apps clients:
/// `apps-server-event {app, name, data}` (`name` is the full name, for
/// example `cmux.cloud.link.changed`). `payload` is the whole event line.
public struct AppServerEvent: Equatable, Sendable {
    public static let eventName = "apps-server-event"

    public let app: String
    public let name: String
    public let payload: JSONValue

    public init(app: String, name: String, payload: JSONValue) {
        self.app = app
        self.name = name
        self.payload = payload
    }

    /// The app server event in `event`, or nil.
    public init?(_ event: DaemonEvent) {
        guard case .unknown(Self.eventName, let payload) = event,
              let app = payload["app"]?.stringValue, let name = payload["name"]?.stringValue else { return nil }
        self.init(app: app, name: name, payload: payload)
    }
}
