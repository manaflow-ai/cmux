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
                return try await slackRequest(configuration: configuration, auth: auth, identity: identity, method: method,
                                              ownBot: ownBot.map { ($0.configToken, $0.name) })
            } catch let error as CloudAPIError { throw PageError(code: "cmux.slack." + error.code, message: error.code) }
        }, open: { url in LinkRouter.shared.open(url) }, awake: { [weak auth] allowance in
            guard let auth else { throw PageError.closed }
            guard let chief = chief() else { throw PageError(code: "cmux.slack.no_chief", message: "no_chief") }
            do {
                return try await slackAwake(configuration: configuration, auth: auth, chief: chief, allowance: allowance)
            } catch let error as CloudAPIError { throw PageError(code: "cmux.slack." + error.code, message: error.code) }
        })
    }

    /// A Slack route in the signed-in person's team with this Mac's install token, on the artifacts API, through the
    /// daemon's `owner.slack`. The app injects its existing identity; credentials never cross the page bridge.
    @MainActor
    static func slackRequest(configuration: CloudConfiguration, auth: CloudAuth, identity: MacInstallIdentity, method: String,
                             ownBot: (configToken: String, name: String?)?) async throws -> Data {
        guard auth.isSignedIn else { throw CloudAPIError.notSignedIn }
        guard let base = configuration.artifactsAPIBaseURL() else {
            throw CloudAPIError.http(status: 501, code: "unavailable", message: nil)
        }
        let team = try auth.accessTokenTeam(requested: nil)
        let client = CloudDaemon.workerMachines(baseURL: base, accessToken: { try await identity.accessToken(team: team).accessToken },
                                                teamID: { team }, machineIO: auth.machineIO, buildSpace: configuration.buildSpace)
        return try await client.slackRequest(method: method, ownBot: ownBot)
    }

    /// The default Chief's Slack-awake setting with the person's own Stack session (the API takes only the owner's
    /// session for the PUT, never this Mac's install token), through the daemon's `owner.slack_awake`.
    @MainActor
    static func slackAwake(configuration: CloudConfiguration, auth: CloudAuth, chief: String, allowance: Int??) async throws -> Data {
        guard auth.isSignedIn else { throw CloudAPIError.notSignedIn }
        let team = try auth.accessTokenTeam(requested: nil)
        let client = CloudDaemon.workerMachines(baseURL: configuration.ownerAPIBaseURL(), accessToken: { [auth] in try await auth.tokens().access },
                                                teamID: { team }, machineIO: auth.machineIO, buildSpace: configuration.buildSpace)
        return try await client.slackAwake(chief: chief, allowance: allowance)
    }
}
