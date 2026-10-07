import Foundation

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
