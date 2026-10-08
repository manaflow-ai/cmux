import Foundation

/// Screen group changes as protocol-v2 state operations (`state-resources-v1`,
/// `screen_group.*`): each carries the client's idempotency key (a request
/// sent again with the same key replays the stored result instead of
/// applying twice; the app does not resend today), and the daemon
/// commits it on the same path as the raw `screen-groups-v1` commands
/// (cmux-tui `mux/state_screens.rs`). Screens and groups are named by their
/// public ids (`ScreenModel.id`, `ScreenGroupID`). Its own type, not a
/// `DaemonConnection` extension (that type's line budget is frozen).
public struct ScreenGroupStateClient: Sendable {
    public let connection: DaemonConnection

    public init(connection: DaemonConnection) {
        self.connection = connection
    }

    /// A `screen_group.*` mutation the app sends.
    public enum Operation: Sendable, Equatable {
        case create(screens: [String], name: String?, color: String?)
        case addScreens(group: String, screens: [String])
        case removeScreens([String])
        case update(group: String, name: String?, color: String?, collapsed: Bool?)
        case ungroup(group: String)

        public var name: String {
            switch self {
            case .create: "screen_group.create"
            case .addScreens: "screen_group.add_screens"
            case .removeScreens: "screen_group.remove_screens"
            case .update: "screen_group.update"
            case .ungroup: "screen_group.ungroup"
            }
        }

        /// The operation's params (wire names of cmux-tui `resource_router/state.rs`).
        public var params: [String: JSONValue] {
            func ids(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }
            var params: [String: JSONValue] = [:]
            switch self {
            case .create(let screens, let name, let color):
                params["screens"] = ids(screens)
                if let name { params["name"] = .string(name) }
                if let color { params["color"] = .string(color) }
            case .addScreens(let group, let screens):
                params["screen_group"] = .string(group)
                params["screens"] = ids(screens)
            case .removeScreens(let screens):
                params["screens"] = ids(screens)
            case .update(let group, let name, let color, let collapsed):
                params["screen_group"] = .string(group)
                if let name { params["name"] = .string(name) }
                if let color { params["color"] = .string(color) }
                if let collapsed { params["collapsed"] = .bool(collapsed) }
            case .ungroup(let group):
                params["screen_group"] = .string(group)
            }
            return params
        }
    }

    /// Sends `operation` with `idempotencyKey` (1 to 128 bytes). Returns
    /// whether the daemon replayed an earlier result for the same key.
    @discardableResult
    public func send(_ operation: Operation, idempotencyKey: String) async throws -> Bool {
        let name = operation.name, params = operation.params
        let result = try await connection.resourceRequest({ id in
            ResourceRequestEnvelope(id: id, operation: name, params: params, idempotencyKey: idempotencyKey)
        }, as: ResourceMutationResult<JSONValue>.self)
        return result.replayed ?? false
    }
}
