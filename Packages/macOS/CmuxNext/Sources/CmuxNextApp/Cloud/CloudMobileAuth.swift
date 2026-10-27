import CmuxNextCloud
import CmuxNextMobile
import CmuxNextWakeups
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
    /// Where `isCurrent` reads the account: one task in the automation class (the phone host asks, not a person).
    private let mainWork: MainWorkScheduler

    /// Nil unless signed in with a user and a team.
    @MainActor init?(auth: CloudAuth, mainWork: MainWorkScheduler) {
        guard auth.isSignedIn, let user = auth.user, let team = auth.teamID else { return nil }
        projectID = auth.configuration.stackProjectID
        userID = user.id
        teamID = team
        self.auth = auth
        self.mainWork = mainWork
    }

    func accessToken(forceRefresh: Bool) async throws -> String {
        if forceRefresh { return try await auth.coordinator.forceRefreshAccessToken() }
        return try await auth.tokens().access
    }

    func isCurrent() async -> Bool {
        let auth = auth, userID = userID, teamID = teamID
        return await mainWork.apply(.automation, owner: "CloudMobileAuth.isCurrent") {
            auth.isSignedIn && auth.user?.id == userID && auth.teamID == teamID
        }
    }
}
