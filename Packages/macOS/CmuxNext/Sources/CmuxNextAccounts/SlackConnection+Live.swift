public import CmuxNextCloud
public import CmuxNextPages
import Foundation

extension SlackPageProvider {
    /// The Settings page's Slack ops over this build's Cloud sign-in: the bearer stays here, the page sees JSON.
    @MainActor
    /// `chief`: the default Chief's id, the one Slack talks to (RFD 0123), or nil before Home has read it.
    public static func live(configuration: CloudConfiguration, auth: CloudAuth, identity: MacInstallIdentity,
                            chief: @escaping @MainActor () -> String? = { nil }) -> SlackPageProvider {
        SlackPageProvider(request: { [weak auth] method, ownBot in
            guard let auth else { throw PageError.closed }
            do {
                return try await CloudAPIClient.slackRequest(configuration: configuration, auth: auth, identity: identity, method: method,
                                                             ownBot: ownBot.map { ($0.configToken, $0.name) })
            } catch let error as CloudAPIError { throw PageError(code: "cmux.slack." + error.code, message: error.code) }
        }, open: { url in LinkRouter.shared.open(url) }, awake: { [weak auth] allowance in
            guard let auth else { throw PageError.closed }
            guard let chief = chief() else { throw PageError(code: "cmux.slack.no_chief", message: "no_chief") }
            do {
                return try await CloudAPIClient.slackAwake(configuration: configuration, auth: auth, chief: chief, allowance: allowance)
            } catch let error as CloudAPIError { throw PageError(code: "cmux.slack." + error.code, message: error.code) }
        })
    }
}
