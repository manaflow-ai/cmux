public import Foundation

/// The cmux account's teams as Settings > Accounts shows them. The active
/// team is the one CodeRouter and every other team-scoped feature use; the
/// App reads it from its one source (`ActiveTeam`), never picks one here.
public struct AccountsTeams: Equatable, Sendable {
    public struct Team: Equatable, Sendable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public var teams: [Team]
    public var activeID: String?
    /// The device is restricted to its organization's team: no switching.
    public var isManaged: Bool
    /// A switch is being saved.
    public var isSwitching: Bool

    public init(teams: [Team] = [], activeID: String? = nil, isManaged: Bool = false, isSwitching: Bool = false) {
        self.teams = teams
        self.activeID = activeID
        self.isManaged = isManaged
        self.isSwitching = isSwitching
    }
}
