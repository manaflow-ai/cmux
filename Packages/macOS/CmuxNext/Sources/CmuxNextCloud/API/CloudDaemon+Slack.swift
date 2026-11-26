public import Foundation

/// The Slack integration's calls (Settings' Slack page): cmux-cloud-api's `owner.slack` and `owner.slack_awake`
/// (`slack.rs`) send them, wait 20 s and check the answers; the app only names the call.
extension CloudDaemon {
    /// One of the three fixed Slack routes by its HTTP method (`GET` the connection, `POST` an install link,
    /// `DELETE` the connection, answered `{}`), or "use your own bot name" (`ownBot`: `POST /v1/slack/apps`).
    /// Sent with this Mac's install token (auth `worker`). The configuration token goes to the daemon on stdin, in this
    /// one request; nothing here stores, caches or logs it, and a refusal of it carries no text the service wrote.
    public func slackRequest(method: String, ownBot: (configToken: String, name: String?)? = nil) async throws -> Data {
        var args: [String: any Sendable]
        if let ownBot {
            args = ["route": "create_app", "configToken": ownBot.configToken]
            if let name = ownBot.name { args["name"] = name }
        } else {
            switch method {
            case "GET": args = ["route": "connection"]
            case "POST": args = ["route": "install_link"]
            case "DELETE": args = ["route": "disconnect"]
            default: throw CloudAPIError.transport("unsupported Slack request method")
            }
        }
        return try await daemon("owner.slack", args, timeout: CloudOwnerAPIClient.bound(.seconds(20)), auth: "worker")
    }

    /// RFD 0123's owner setting: `GET /v1/chiefs/<chief>/slack-awake?days=7` when `allowance` is nil, else `PUT`
    /// `{allowance_seconds}` (`.some(nil)`: back to the 2 h default), with the person's own Stack session (auth `owner`).
    /// `chief` is an `agent_` id; anything else never leaves the app. Answers the reply's `value`.
    public func slackAwake(chief: String, allowance: Int?? = nil) async throws -> Data {
        guard Self.isChiefID(chief) else { throw CloudAPIError.transport("not a Chief id") }
        var args: [String: any Sendable] = ["chief": chief]
        if case .some(let seconds) = allowance { args["allowance"] = seconds.map { $0 as any Sendable } ?? NSNull() }
        return try await daemon("owner.slack_awake", args, timeout: CloudOwnerAPIClient.bound(.seconds(20)), auth: "owner")
    }

    /// A Chief id: `agent_` and 26 Crockford base32 digits (cmux-cloud-api checks it again).
    static func isChiefID(_ id: String) -> Bool {
        id.range(of: #"^agent_[0-9A-HJKMNP-TV-Z]{26}$"#, options: .regularExpression) != nil
    }
}
