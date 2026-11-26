public import CmuxNextCloud
public import Foundation

extension CloudAPIClient {
    /// Relays a Slack request using the current signed-in person's team and this build's platform.
    /// The app injects its existing identity; credentials never cross the page bridge.
    @MainActor
    public static func slackRequest(configuration: CloudConfiguration, auth: CloudAuth,
                                    identity: MacInstallIdentity, method: String,
                                    ownBot: (configToken: String, name: String?)? = nil) async throws -> Data {
        guard auth.isSignedIn else { throw CloudAPIError.notSignedIn }
        guard let base = configuration.artifactsAPIBaseURL() else {
            throw CloudAPIError.http(status: 501, code: "unavailable", message: nil)
        }
        let team = try auth.accessTokenTeam(requested: nil)
        let client = slack(baseURL: base, accessToken: { try await identity.accessToken(team: team).accessToken }, teamID: team)
        if let ownBot { return try await client.slackCreateApp(configToken: ownBot.configToken, name: ownBot.name) }
        return try await client.slackRequest(method: method)
    }

    /// The Slack bridge uses the signed-in person's cmux bearer against cmux-platform.
    /// Like the owner API, this transport never caches credentials or follows redirects.
    /// It lives here, not in CmuxNextCloud (cloud core, where Swift stays minimal): it is the Slack integration's relay.
    public static func slack(baseURL: URL, accessToken: @escaping @Sendable () async throws -> String,
                             teamID: String? = nil, session: URLSession = CloudOwnerAPIClient.transport) -> CloudAPIClient {
        workerMachines(baseURL: baseURL, accessToken: accessToken, teamID: { teamID }, session: session)
    }

    /// Relays one of the three fixed Slack endpoints. Connection state stays in the Settings page.
    public func slackRequest(method: String) async throws -> Data {
        switch method {
        case "GET": return try await sendData("GET", "/v1/slack/connection")
        case "POST": return try await sendData("POST", "/v1/slack/install-link")
        case "DELETE":
            _ = try await sendData("DELETE", "/v1/slack/connection")
            return Data("{}".utf8)
        default: throw CloudAPIError.transport("unsupported Slack request method")
        }
    }

    /// "Use your own bot name": one `POST /v1/slack/apps`. The configuration token goes to the platform in
    /// this one request body; nothing here stores, caches or logs it, and the reply carries the install URL.
    public func slackCreateApp(configToken: String, name: String?) async throws -> Data {
        var body: [String: any Sendable] = ["configToken": configToken]
        if let name { body["name"] = name }
        return try await sendData("POST", "/v1/slack/apps", body: body)
    }

    /// RFD 0123's owner setting on the cmux API: `GET /v1/chiefs/<chief>/slack-awake?days=7` when `allowance` is nil,
    /// else `PUT` with `{allowance_seconds}` (`.some(nil)`: back to the 2 h default). It goes as the person's own Stack
    /// session, never this Mac's install token: the API takes only the owner's session for the PUT. Returns the reply's `value`.
    @MainActor
    public static func slackAwake(configuration: CloudConfiguration, auth: CloudAuth, chief: String,
                                  allowance: Int?? = nil) async throws -> Data {
        guard auth.isSignedIn else { throw CloudAPIError.notSignedIn }
        let team = try auth.accessTokenTeam(requested: nil)
        let client = workerMachines(baseURL: configuration.ownerAPIBaseURL(), accessToken: { [auth] in try await auth.tokens().access },
                                    teamID: { team }, session: CloudOwnerAPIClient.transport, buildSpace: configuration.buildSpace)
        return try await client.slackAwake(chief: chief, allowance: allowance)
    }

    /// One `slack-awake` read or write for `chief` (an `agent_` id; anything else never leaves the app).
    public func slackAwake(chief: String, allowance: Int?? = nil) async throws -> Data {
        guard chief.range(of: #"^agent_[0-9A-HJKMNP-TV-Z]{26}$"#, options: .regularExpression) != nil else {
            throw CloudAPIError.transport("not a Chief id")
        }
        let path = "/v1/chiefs/\(chief)/slack-awake"
        let reply: Data
        switch allowance {
        case .none: reply = try await sendData("GET", path + "?days=7")
        case .some(let seconds):
            let value: any Sendable = seconds.map { $0 as any Sendable } ?? NSNull()
            reply = try await sendData("PUT", path, body: ["allowance_seconds": value])
        }
        // The API answers `{ok: true, value}`; the page reads only the value.
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any], let value = object["value"] as? [String: Any] else {
            throw CloudAPIError.transport("unexpected slack-awake reply")
        }
        return try JSONSerialization.data(withJSONObject: value)
    }
}
