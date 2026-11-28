import CmuxNextCloud
import CmuxNextMobile
import Foundation

/// The signed-in Stack account as phone access sees it: one account and
/// team captured at start. `isCurrent` turns false after sign-out or a
/// user or team switch, which stops the host; `AppServices` then starts a
/// new one for the new account.
struct CloudMobileAuth: MobileHostAuth {
    let projectID: String
    let userID: String
    let teamID: String
    private let auth: CloudAuth

    /// Nil unless signed in with a user and a team.
    @MainActor init?(auth: CloudAuth) {
        guard auth.isSignedIn, let user = auth.user, let team = auth.teamID else { return nil }
        projectID = auth.configuration.stackProjectID
        userID = user.id
        teamID = team
        self.auth = auth
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { return try await auth.coordinator.forceRefreshAccessToken() }
        return try await auth.tokens().access
    }

    func isCurrent() async -> Bool {
        await MainActor.run { auth.isSignedIn && auth.user?.id == userID && auth.teamID == teamID }
    }
}
