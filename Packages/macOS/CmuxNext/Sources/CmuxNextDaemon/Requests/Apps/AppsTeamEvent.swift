import Foundation

/// `apps-team-event {event, data}`: one Cloud event the app received pushed (a machine's state socket,
/// cmux-platform `MachineState`). The daemon passes it to the first-party Cloud server as a `team.event` line,
/// which applies it to its machine projection (`first-party-apps/cloud/server/src/api/events.rs`). Verified app
/// connection only; answers `{servers: N}`.
public struct AppsTeamEventRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-team-event"

    public var event: String
    public var data: JSONValue

    public init(event: String, data: JSONValue) {
        self.event = event
        self.data = data
    }

    /// `data` is the platform's own JSON: sent verbatim (`verbatimFields`), not through the snake case key strategy.
    enum CodingKeys: String, CodingKey {
        case event
    }
}

extension AppsTeamEventRequest: VerbatimFieldsRequest {
    var verbatimFields: [String: JSONValue] { ["data": data] }
}
