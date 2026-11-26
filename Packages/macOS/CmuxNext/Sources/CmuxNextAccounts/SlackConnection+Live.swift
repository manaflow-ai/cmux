public import CmuxNextCloud
public import CmuxNextPages
import Foundation

extension SlackPageProvider {
    /// The Settings page's Slack ops over this build's Cloud sign-in: the bearer stays here, the page sees JSON.
    @MainActor
    public static func live(configuration: CloudConfiguration, auth: CloudAuth, identity: MacInstallIdentity) -> SlackPageProvider {
        SlackPageProvider(request: { [weak auth] method, ownBot in
            guard let auth else { throw PageError.closed }
            do {
                return try await CloudAPIClient.slackRequest(configuration: configuration, auth: auth, identity: identity, method: method,
                                                             ownBot: ownBot.map { ($0.configToken, $0.name) })
            } catch let error as CloudAPIError { throw PageError(code: "cmux.slack." + error.code, message: error.code) }
        }, open: { url in LinkRouter.shared.open(url) })
    }
}
