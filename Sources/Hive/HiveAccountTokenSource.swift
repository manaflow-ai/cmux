import CmuxAuthRuntime
import Foundation

@MainActor
struct HiveAccountTokenSource {
    let auth: AuthCoordinator
    let identity: AuthenticatedSessionIdentity
    let teamID: String?

    enum Failure: Error { case accountChanged }

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
        guard auth.authenticatedSessionIdentity == identity, auth.resolvedTeamID == teamID else {
            throw Failure.accountChanged
        }
    }
}
