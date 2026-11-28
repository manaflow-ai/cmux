import Foundation

/// `apps-machine-state-watch {machines, platform, team?}`: the Cloud machines the app shows. The daemon holds each
/// one's state socket (`GET /v1/cloud/machines/{id}/state` on `platform`, with the person's lease bearer and `team`),
/// applies every frame to the Cloud app server itself and answers with `apps-cloud-machine` events
/// (`{machine, kind: record | live | lost, record?}`). The list replaces this connection's earlier one; an empty
/// list closes its sockets. Verified app connection only.
public struct AppsMachineStateWatchRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-machine-state-watch"

    /// The machine records, as the app holds them (a JSON array, sent as they are).
    public var machines: JSONValue
    public var platform: String
    public var team: String?

    public init(machines: JSONValue, platform: String, team: String?) {
        self.machines = machines
        self.platform = platform
        self.team = team
    }

    /// The records' own camel case field names go on the wire byte for byte (`verbatimFields`).
    enum CodingKeys: String, CodingKey {
        case platform, team
    }
}

extension AppsMachineStateWatchRequest: VerbatimFieldsRequest {
    var verbatimFields: [String: JSONValue] { ["machines": machines] }
}
