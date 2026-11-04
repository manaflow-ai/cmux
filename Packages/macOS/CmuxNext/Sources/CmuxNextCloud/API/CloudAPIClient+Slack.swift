public import Foundation

extension CloudAPIClient {
    /// Relays a Slack request using the current signed-in person's team and this build's platform.
    /// The app injects its existing identity; credentials never cross the page bridge.
    @MainActor
    public static func slackRequest(configuration: CloudConfiguration, auth: CloudAuth,
                                    identity: MacInstallIdentity, method: String) async throws -> Data {
        guard auth.isSignedIn else { throw CloudAPIError.notSignedIn }
        guard let base = configuration.artifactsAPIBaseURL() else {
            throw CloudAPIError.http(status: 501, code: "unavailable", message: nil)
        }
        let team = try auth.accessTokenTeam(requested: nil)
        let client = slack(baseURL: base, accessToken: { try await identity.accessToken(team: team).accessToken }, teamID: team)
        return try await client.slackRequest(method: method)
    }

    /// The Slack bridge uses the signed-in person's cmux bearer against cmux-platform.
    /// Like the owner API, this transport never caches credentials or follows redirects.
    public static func slack(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                             teamID: String? = nil) -> CloudAPIClient {
        slack(baseURL: baseURL, accessToken: accessToken, teamID: teamID, session: CloudOwnerAPIClient.transport)
    }

    static func slack(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                      teamID: String?, session: URLSession) -> CloudAPIClient {
        workerMachines(baseURL: baseURL, accessToken: accessToken, teamID: { teamID }, session: session)
    }

    /// Relays one of the three fixed Slack endpoints. Connection state stays in the Settings page.
    public func slackRequest(method: String) async throws -> Data {
        switch method {
        case "GET": return try await sendData("GET", "/v1/slack/connection")
        case "POST": return try await sendData("POST", "/v1/slack/install-link")
        case "DELETE":
            _ = try await send("DELETE", "/v1/slack/connection", as: Ignored.self)
            return Data("{}".utf8)
        default: throw CloudAPIError.transport("unsupported Slack request method")
        }
    }
}
