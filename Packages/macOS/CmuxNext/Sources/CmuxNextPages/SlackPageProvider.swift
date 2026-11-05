public import CmuxNextSettings
public import Foundation

/// Forwards the Settings page's Slack requests without exposing its Cloud bearer to JavaScript.
/// OAuth and connection state live in TypeScript; native code owns transport and browser handoff.
@MainActor
public final class SlackPageProvider: PageProvider {
    private let request: @MainActor (String) async throws -> Data
    private let open: @MainActor (URL) -> Void

    /// The host supplies a credential-isolated request and the system-browser opener.
    public init(request: @escaping @MainActor (String) async throws -> Data,
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
            return try JSONValue.parse(await request(method))
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
