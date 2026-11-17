import Foundation

/// `apps-page-call`: one bridge message of an app's web pane (`render: web`). `message` is the
/// page's raw `{id, op, params}` text, so the daemon applies its size limit before it parses
/// anything; `page` names the open page (each has its own call budget). The daemon checks the
/// call against the app's grant (cmux-tui-core apps/page_calls.rs) and answers the page's
/// `{id, ok, value | error}`. Only the verified cmux app connection may send it.
public struct AppsPageCallRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-page-call"

    public var app: String
    public var page: String
    public var message: String

    public init(app: String, page: String, message: String) {
        self.app = app
        self.page = page
        self.message = message
    }
}
