import CmuxNextCloud
import Foundation

/// Set Up GitHub on This Machine asks first whether the machine's team can use the cmux GitHub App
/// (``CloudGitHubApp``), with the person's own session against the API Worker, for the team the
/// install token names (the team whose Cloud machines the Worker holds, as the approvals route uses).
extension CloudService {
    /// The whole check, install token included, within ``gitHubAppDeadline``: with the setup exec
    /// after it (``CloudGitHubSetup/timeoutMs`` plus its send margin) it stays inside `action.run`'s
    /// 40 s result deadline. A check that misses it is ``CloudGitHubApp/unknown``: the device flow.
    func gitHubApp() async -> CloudGitHubApp {
        let auth = auth, identity = installIdentity
        let signedInTeam = auth.teamID
        let baseURL = FeedService.apiBaseURL(auth: auth)
        let accessToken: @Sendable () async throws -> String = { try await auth.tokens().access }
        let answer = try? await withDeadline(Self.gitHubAppDeadline, label: "GitHub App check") {
            let claimed = (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:))
            guard let team = claimed ?? signedInTeam else { return CloudGitHubApp.unknown }
            let owner = CloudOwnerAPIClient(baseURL: baseURL, accessToken: accessToken, teamID: { team })
            return await owner.gitHubApp(team: team)
        }
        return answer ?? .unknown
    }

    /// 8 s for the App check, then at most 30 s for the setup exec (25 s plus 5 s), under 40 s.
    static let gitHubAppDeadline: Duration = .seconds(8)
}
