public import CmuxNextSettings
public import Foundation

/// Forwards the Settings page's Slack requests without exposing its Cloud bearer to JavaScript.
/// OAuth and connection state live in TypeScript; native code owns transport and browser handoff.
@MainActor
public final class SlackPageProvider: PageProvider {
    private let request: @MainActor (String, SlackOwnBot?) async throws -> Data
    private let open: @MainActor (URL) -> Void

    /// The host supplies a credential-isolated request and the system-browser opener.
    public init(request: @escaping @MainActor (String, SlackOwnBot?) async throws -> Data,
         open: @escaping @MainActor (URL) -> Void) {
        self.request = request
        self.open = open
    }

    /// Relays a fixed Slack operation; the page cannot choose the authenticated request URL.
    public func call(_ op: String, params: JSONValue, context: PageCallContext) async throws -> JSONValue {
        switch op {
        case "cmux.settings.slack.request":
            guard let method = params["method"]?.stringValue, ["GET", "POST", "DELETE"].contains(method) else {
                throw PageError.invalidParams("method must be GET, POST or DELETE")
            }
            return try JSONValue.parse(await request(method, nil))
        case "cmux.settings.slack.create_app":
            // The token is forwarded once to the platform and dropped; it is not kept, echoed or logged here.
            guard let token = params["configToken"]?.stringValue, token.hasPrefix("xoxe.xoxp-"), token.count <= 1100 else {
                throw PageError.invalidParams("expected a Slack app configuration token")
            }
            let name = params["name"]?.stringValue
            return try JSONValue.parse(await request("POST", SlackOwnBot(configToken: token, name: name)))
        case "cmux.settings.slack.open":
            guard let text = params["url"]?.stringValue, let url = URL(string: text), url.scheme == "https",
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
                throw PageError.invalidParams("expected an HTTPS install URL")
            }
            open(url)
            return .object([:])
        default: throw PageError.unknownOp(op)
        }
    }
}

/// A person's Slack app configuration token and the bot name they want. Never persisted or logged.
public struct SlackOwnBot: Sendable {
    public let configToken: String
    public let name: String?

    public init(configToken: String, name: String?) {
        self.configToken = configToken
        self.name = name
    }
}

/// The platform's Allow-page return link, `cmux://slack/connected` (or this build's scheme).
public enum SlackConnectedLink {
    /// Shows Settings > Accounts with a one-shot hint to re-read the connection, and reports whether `url` was the link.
    /// The link carries nothing the page trusts: the page asks Cloud which workspace is connected.
    @MainActor
    public static func handle(_ url: URL, scheme: String, show: (String) -> Void) -> Bool {
        guard let urlScheme = url.scheme?.lowercased(), ["cmux", scheme.lowercased()].contains(urlScheme),
              url.host?.lowercased() == "slack", url.path == "/connected" else { return false }
        show("#/settings/accounts?slack=connected&open=\(UUID().uuidString)")
        return true
    }
}
