import Foundation

/// `apps-open-link`: a link the person clicked, offered to the app whose
/// `cmux.opener/1` matches it (cmux-tui-core `apps/openers.rs`; the daemon
/// picks the app). Answers `{handled: true, app}` when that app opened it,
/// else `{handled: false}` (with `app` and `error` when its opener failed),
/// and the caller opens the link itself.
public struct AppsOpenLinkRequest: DaemonRequest {
    public typealias Response = JSONValue
    public static let command = "apps-open-link"

    public var url: String
    /// `user` needs the verified cmux app connection, as for `apps-run`.
    public var origin: AppsRunRequest.Origin

    public init(url: String, origin: AppsRunRequest.Origin) {
        self.url = url
        self.origin = origin
    }
}
