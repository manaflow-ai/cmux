public import CmuxNextSettings
public import Foundation

/// Forwards the Settings page's Slack requests without exposing its Cloud bearer to JavaScript.
/// OAuth and connection state live in TypeScript; native code owns transport and browser handoff.
@MainActor
public final class SlackPageProvider: PageProvider {
    private let request: @MainActor (String, SlackOwnBot?) async throws -> Data
    private let open: @MainActor (URL) -> Void
    private let awake: @MainActor (Int??) async throws -> Data

    /// The host supplies a credential-isolated request, the system-browser opener and RFD 0123's awake-time
    /// read/write for the default Chief (`nil`: read; `.some(nil)`: the default allowance; `.some(n)`: n seconds).
    public init(request: @escaping @MainActor (String, SlackOwnBot?) async throws -> Data,
         open: @escaping @MainActor (URL) -> Void,
         awake: @escaping @MainActor (Int??) async throws -> Data = SlackPageProvider.noChief) {
        self.request = request
        self.open = open
        self.awake = awake
    }

    /// The awake read/write when the host has no Chief. A named function, not a closure literal default: Swift emits an
    /// async closure default in every calling module under one weak symbol (crash class async_closure_default_arg).
    @MainActor
    public static func noChief(_: Int??) async throws -> Data { throw PageError.unavailable("no Chief") }

    /// The most a non-owner may keep the Chief awake a day (the API's `SLACK_ALLOWANCE_MAX_SECONDS`).
    public static let maxAllowanceSeconds = 86_400

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
        case "cmux.settings.slack.awake":
            // No `allowance_seconds`: read. `null`: the default. A whole number of seconds in 0...max: set it.
            guard let allowance = params["allowance_seconds"] else { return try JSONValue.parse(await awake(nil)) }
            if case .null = allowance { return try JSONValue.parse(await awake(.some(nil))) }
            guard let seconds = allowance.doubleValue, seconds.rounded() == seconds, (0...Double(Self.maxAllowanceSeconds)).contains(seconds) else {
                throw PageError.invalidParams("allowance_seconds is whole seconds in 0...86400, or null")
            }
            return try JSONValue.parse(await awake(.some(Int(seconds))))
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
public struct SlackConnectedLink {
    public init() {}
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
