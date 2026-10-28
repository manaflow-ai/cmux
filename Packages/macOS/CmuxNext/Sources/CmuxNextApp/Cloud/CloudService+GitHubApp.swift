import CmuxNextCloud
import Foundation

/// Set Up GitHub on This Machine asks first whether the machine's team can use the cmux GitHub App
/// (``CloudGitHubApp``), with the person's own session against the API Worker, for the team the
/// install token names (the team whose Cloud machines the Worker holds, as the approvals route uses).
extension CloudService {
    func gitHubApp() async -> CloudGitHubApp {
        let auth = auth
        let claimed = (try? await installIdentity.installToken()).flatMap(MacInstallIdentity.team(ofToken:))
        guard let team = claimed ?? auth.teamID else { return .unknown }
        let owner = CloudOwnerAPIClient(baseURL: FeedService.apiBaseURL(auth: auth),
                                        accessToken: { try await auth.tokens().access }, teamID: { team })
        return await owner.gitHubApp(team: team)
    }
}
