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
    /// The capability a daemon advertises in `identify` when it serves
    /// `command`, or nil for a protocol 12 base command. Every machine runs
    /// its own cmux-tui build (a Cloud VM keeps its image's daemon until it
    /// upgrades), so `DaemonConnection.request` refuses the command with
    /// `DaemonError.missingCapabilities` before it reaches a daemon that
    /// does not advertise this, instead of sending a command that daemon
    /// answers with "unknown variant".
    static var requiredCapability: String? { get }
}

extension DaemonRequest {
    public static var requiredCapability: String? { nil }

    /// Throws `missingCapabilities` when `identity` does not advertise
    /// ``requiredCapability``; the request must then not be sent.
    static func requireServed(by identity: DaemonIdentity?) throws {
        guard let capability = requiredCapability, identity?.supports(capability) != true else { return }
        throw DaemonError.missingCapabilities([capability])
    }
}

/// A command whose reply waits for cmux-tui to launch a terminal host.
/// cmux-tui bounds that launch by its own host handshake (2 s) and connect
/// retry (1 s) windows, so these use `Configuration.spawnTimeout` instead of
/// the 2 s control-plane deadline: a client that gives up first reports a
/// failure for a tab the daemon then creates.
public protocol TerminalSpawningRequest: DaemonRequest {}

/// `{}` responses.
public struct EmptyResponse: Decodable, Sendable, Equatable {
    public init() {}
}

extension EmptyResponse {
    public init(from decoder: any Decoder) throws {
        self.init()
    }
}
