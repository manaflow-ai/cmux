import Foundation

/// The backend's ids of an account and its teams (backend `domains/user.ts`, derived so routing
/// needs no lookup), from Rust (cmux-cloud-config `identity`, `cloud_identity_team_ids`): the one
/// rule every caller uses, so no Swift copy of the hashing drifts from it. An active team is a
/// Stack team id, or the personal team's backend id (`team_` and 20 hex digits; Stack ids never
/// are), and ``teamHeader(project:team:)`` names either as the backend does.
public nonisolated enum CloudTeamIDs {
    private struct Request: Encodable { var project: String, stackUser: String?, team: String? }
    private struct Reply: Decodable { var workerUser: String?, personalTeam: String?, teamHeader: String? }

    private static func ids(project: String, stackUser: String? = nil, team: String? = nil) -> Reply? {
        CloudStartCore().call("cloud_identity_team_ids", Request(project: project, stackUser: stackUser, team: team),
                              as: Reply.self)
    }

    /// A Stack user's backend id (`userIdFor`): the conversations' participant and a machine's `creator`.
    /// Empty only when the FFI does not answer, an id no owner accepts.
    public static func workerUser(project: String, stackUser: String) -> String {
        ids(project: project, stackUser: stackUser)?.workerUser ?? ""
    }

    /// A Stack user's personal team (`personalTeamIdFor`), where their own Cloud grant applies; Stack
    /// never lists it. Nil when the FFI does not answer.
    public static func personalTeam(project: String, stackUser: String) -> String? {
        ids(project: project, stackUser: stackUser)?.personalTeam
    }

    /// Whether an active team is a backend team (`team_` and 20 lowercase hex digits, Rust's `identity::is_team`):
    /// the personal team, never a Stack id. Stack's own APIs (its team routes, the legacy VM and runs APIs'
    /// `X-Cmux-Team-Id`, CodeRouter) know only Stack teams, so a caller leaves such a team out of them.
    public static func isPlatformTeam(_ team: String) -> Bool { CloudAccessToken.isTeam(team) }

    /// The `x-cmux-team` of an active team: the personal team as is, a Stack team's `stackTeamIdFor`.
    /// Empty only when the FFI does not answer, a team no owner accepts.
    public static func teamHeader(project: String, team: String) -> String {
        ids(project: project, team: team)?.teamHeader ?? ""
    }
}
