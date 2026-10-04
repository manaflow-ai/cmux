public import Foundation

/// Maps the bundled CLI's `cmux server status --json` and `cmux host roles
/// --json` into a `ServerSnapshot` (not implemented yet).
public nonisolated enum LocalServerStatus {
    public struct Malformed: Error, Equatable {}
    public struct NotServerStatus: Error, Equatable {}

    public static func snapshot(status: Data, roles: Data?, hostName: String) throws -> ServerSnapshot {
        throw Malformed()
    }

    public static func roleState(_ raw: String) -> ServerRoleState { .unavailable }
}
