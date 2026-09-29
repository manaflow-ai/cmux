import Foundation

// Typed raw protocol v12 commands live under Requests/, one domain per folder.
// Field names are camelCase and become snake_case on the wire. Sources:
// cmux-tui/spec/commands.md and the server's `Command` enum
// (crates/cmux-tui-core/src/server.rs), plus the feat-cmux-next-daemon branch
// for the `*-v1` capabilities it adds. Requests still marked
// TODO(feat-cmux-next-daemon) are proposed and not served yet; they fail with
// "unknown variant" on current daemons.

/// One raw protocol v12 command. Conformers encode only their own fields;
/// the envelope adds `id` and `cmd`. Property names are converted to
/// snake_case on the wire (`mutationID` -> `mutation_id`).
public protocol DaemonRequest: Encodable, Sendable {
    associatedtype Response: Decodable & Sendable
    /// Wire command name, e.g. `"list-workspaces"`.
    static var command: String { get }
}

/// `{}` responses.
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
}

extension EmptyResponse {
    public init(from decoder: any Decoder) throws {
        self.init()
    }
}
