import CmuxNextAgentPane
import CmuxNextDaemonService
import Foundation

extension AppServices {
    /// One Cloud environment editor request (`cloud.environment.list/get/update/create/derive`) for the
    /// composer's Environment chip and Settings > Cloud > Cloud Environments alike: the local daemon sends it to
    /// the platform's `/v1/cloud-environments` with this app's install token for the signed-in team, so both
    /// edit the same environments, the account's Default among them (the image and setup new Cloud
    /// machines start from). Refused, with nothing sent, while Cloud is off or not signed in.
    @MainActor
    func runCloudEnvironment(_ request: AgentPaneCloudEnvironmentRequest) async -> [String: Any] {
        await request.run(
            allowed: !registry.disabledFeatures.contains(.cloud) && cloud.mayCallCloud,
            connection: machines.local.connection, platform: cloud.configuration.artifactsAPIBaseURL()) { [cloud] in
                let team = try await cloud.auth.accessTokenTeam(requested: nil)
                return (try await cloud.installIdentity.accessToken(team: team)).accessToken
            }
    }
}
