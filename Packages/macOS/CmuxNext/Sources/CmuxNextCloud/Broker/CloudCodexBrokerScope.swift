public import Foundation

/// The account scope that owns one local Codex refresh-token holder. The scope is
/// captured when the broker is created and must not change while it serves VMs.
nonisolated public struct CloudCodexBrokerScope: Sendable, Equatable, Hashable {
    public let userID: String
    public let teamID: String?

    nonisolated public init(userID: String, teamID: String?) {
        self.userID = userID
        self.teamID = teamID
    }
}

