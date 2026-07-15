/// The authenticated owner of persisted phone-local browser history.
public struct BrowserPersistenceScope: Codable, Equatable, Hashable, Sendable {
    /// The authenticated Stack user identifier.
    public let userID: String
    /// The selected Stack team identifier, when one is selected.
    public let teamID: String?

    /// Creates an authenticated browser persistence scope.
    public init(userID: String, teamID: String?) {
        self.userID = userID
        self.teamID = teamID
    }
}
