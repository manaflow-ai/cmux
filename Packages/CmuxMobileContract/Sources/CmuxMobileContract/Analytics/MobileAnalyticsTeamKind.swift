import Foundation

/// Whether an analytics event is attributed to a personal or shared team.
public enum MobileAnalyticsTeamKind: String, Codable, Equatable, Sendable {
    /// A personal team owned by a single user.
    case personal

    /// A shared team with multiple members.
    case shared
}
