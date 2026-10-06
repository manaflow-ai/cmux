public import Foundation

/// One `cloud.link.changed` event of the Cloud app server, as the daemon
/// broadcasts it: `apps-server-event {app: "cmux/cloud", name:
/// "cmux.cloud.link.changed", data: {machine, state, generation?, reason?}}`.
public struct CloudLinkChange: Equatable, Sendable {
    public enum State: String, Sendable {
        case up
        case down
        case revoked
    }

    public static let eventName = "cmux.cloud.link.changed"

    public let key: CloudLinkKey
    public let state: State
    /// The carrier generation (`up`, `down`); nil for `revoked`.
    public let generation: UInt64?
    public let reason: String?

    public init(key: CloudLinkKey, state: State, generation: UInt64?, reason: String?) {
        self.key = key
        self.state = state
        self.generation = generation
        self.reason = reason
    }

    private struct Event: Decodable {
        struct Payload: Decodable {
            var machine: String
            var state: String
            var generation: UInt64?
            var reason: String?
        }

        var app: String
        var name: String
        var data: Payload?
    }

    /// The change in an `apps-server-event` line (JSON); nil for any other
    /// event, another app, or a payload without a machine and known state.
    public static func parse(appServerEvent: Data) -> CloudLinkChange? {
        guard let event = try? JSONDecoder().decode(Event.self, from: appServerEvent),
              event.name == eventName, let data = event.data,
              let key = CloudLinkKey(app: event.app, target: data.machine),
              let state = State(rawValue: data.state) else { return nil }
        return CloudLinkChange(key: key, state: state, generation: data.generation, reason: data.reason)
    }
}
