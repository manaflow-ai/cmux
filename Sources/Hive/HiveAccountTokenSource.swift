import CmuxAuthRuntime
import Foundation

@MainActor
struct HiveAccountTokenSource {
    let auth: AuthCoordinator
    let identity: AuthenticatedSessionIdentity
    let teamID: String?
    private let validatesTeamScope: Bool

    enum Failure: Error { case accountChanged }

    init(auth: AuthCoordinator, identity: AuthenticatedSessionIdentity, teamID: String?) {
        self.auth = auth
        self.identity = identity
        self.teamID = teamID
        self.validatesTeamScope = true
    }

    /// Creates credentials for account-wide discovery. Device presence and
    /// ownership are scoped to the signed-in user, so selecting another team
    /// must not invalidate this source.
    init(accountScopedAuth auth: AuthCoordinator, identity: AuthenticatedSessionIdentity) {
        self.auth = auth
        self.identity = identity
        self.teamID = nil
        self.validatesTeamScope = false
    }

    func session() async throws -> AuthenticatedSessionSnapshot {
        try validate()
        let session = try await auth.authenticatedSessionSnapshot()
        try validate()
        guard session.accountID == identity.accountID, session.generation == identity.generation else {
            throw Failure.accountChanged
        }
        return session
    }

    func cachedToken() async -> String? {
        guard (try? validate()) != nil else { return nil }
        let token = await auth.storedAccessToken()
        guard (try? validate()) != nil else { return nil }
        return token
    }

    func refresh() async throws -> String {
        try validate()
        let token = try await auth.forceRefreshAccessToken()
        try validate()
        return token
    }

    private func validate() throws {
        guard auth.authenticatedSessionIdentity == identity,
              !validatesTeamScope || auth.resolvedTeamID == teamID else {
            throw Failure.accountChanged
        }
    }
}
