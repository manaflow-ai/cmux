import CmuxNextCloud
import CmuxNextCompat
import Foundation

/// Set Up GitHub on This Machine asks first whether the machine's team can use the cmux GitHub App
/// (``CloudGitHubApp``), with the person's own session against the API Worker, for the selected team
/// (the one the setup exec and the machine's token asks go to), else the team the install token names.
extension CloudService {
    /// The whole check, install token included, answers within ``gitHubAppDeadline``: with the setup
    /// exec after it (``CloudGitHubSetup/timeoutMs`` plus its send margin) it stays inside
    /// `action.run`'s 40 s result deadline. A check that misses it is ``CloudGitHubApp/unknown``: the
    /// device flow.
    func gitHubApp() async -> CloudGitHubApp {
        let auth = auth, identity = installIdentity
        let signedInTeam = try? auth.accessTokenTeam(requested: nil) // the backend `team_…` id the route takes, never the Stack team id
        let baseURL = FeedService.apiBaseURL(auth: auth), buildSpace = auth.configuration.buildSpace
        let accessToken: @Sendable () async throws -> String = { try await auth.tokens().access }
        return await Self.firstAnswer(within: Self.gitHubAppDeadline, otherwise: .unknown) {
            // The selected team first: a shared-team machine's tokens come from that team's connection.
            let claimed = signedInTeam == nil ? (try? await identity.installToken()).flatMap(MacInstallIdentity.team(ofToken:)) : nil
            guard let team = signedInTeam ?? claimed else { return CloudGitHubApp.unknown }
            let owner = CloudOwnerAPIClient(baseURL: baseURL, accessToken: accessToken, teamID: { team }, buildSpace: buildSpace)
            return await owner.gitHubApp(team: team)
        }
    }

    /// 8 s for the App check, then at most 30 s for the setup exec (25 s plus 5 s), under 40 s.
    static let gitHubAppDeadline: Duration = .seconds(8)

    /// `work`'s answer, or `fallback` once `deadline` passes, never waiting for `work` to stop (``CloudFirstAnswer``).
    nonisolated static func firstAnswer<T: Sendable>(within deadline: Duration, otherwise fallback: T, _ work: @escaping @Sendable () async -> T) async -> T {
        await CloudFirstAnswer.value(within: deadline, otherwise: fallback, work)
    }
}
