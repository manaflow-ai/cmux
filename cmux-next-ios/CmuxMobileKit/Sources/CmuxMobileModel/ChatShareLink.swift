import Foundation

/// A chat share link the phone opens: a guest link (`https://share.cmux.dev/g/<id>#<secret>`), an
/// invite (`https://share.cmux.dev/i/<id>`), or the guest page's open-in-app form
/// (`<scheme>://share?link=<page>#<secret>`). The grammar is the Mac daemon's
/// (`cmux-tui-core` `agent_session_share_link.rs`): an id of 16 to 128 URL-safe characters, and a
/// secret of 8 to 128 in the fragment, which no request ever carries.
///
/// The app opens the page signed in as the phone's own cmux account, so the person joins the
/// shared chat as themselves: ``handoffURL`` mints a one-time code for the page with the account's
/// token (cmux-platform `POST /v1/chat-shares/<id>/handoff`), and ``pageURL(handoff:)`` is the page
/// with that code. Only a known share host's page is opened this way; the token never goes to
/// any other host.
public struct ChatShareLink: Hashable, Sendable {
    /// `g`: a guest link's page; `i`: an invite's.
    public enum Page: String, Hashable, Sendable {
        case guest = "g"
        case invite = "i"
    }

    /// `https://<share host>`, the origin the page and its hand-off are on.
    public let origin: String
    public let page: Page
    public let shareID: String
    /// The guest link's secret (`#<secret>`); nil for an invite, which is joined by account.
    public let secret: String?

    /// The hosts that serve cmux chat share pages: the share host, and the platform's own
    /// workers.dev origins (links made before the share host, which move to it).
    public static let hosts: Set<String> = [
        "share.cmux.dev",
        "cmux-platform-production.debussy.workers.dev",
        "cmux-platform-staging.debussy.workers.dev",
    ]

    public init?(origin: String, page: Page, shareID: String, secret: String?) {
        guard Self.isID(shareID), secret.map(Self.isSecret) ?? true else { return nil }
        self.origin = origin
        self.page = page
        self.shareID = shareID
        self.secret = secret
    }

    /// The share link `url` names, or nil when it is not one (another host, path or scheme, a
    /// malformed id or secret).
    public init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              let scheme = components.scheme?.lowercased() else { return nil }
        if scheme == "https" {
            self.init(page: components)
            return
        }
        // The guest page's open-in-app link carries the page, and the secret in its own fragment.
        guard CmuxLink.isLinkScheme(scheme), components.host?.lowercased() == "share",
              components.path.isEmpty || components.path == "/" else { return nil }
        let links = (components.queryItems ?? []).filter { $0.name == "link" }
        guard links.count == 1, let text = links[0].value, var inner = URLComponents(string: text),
              inner.scheme?.lowercased() == "https" else { return nil }
        // `?app=<scheme>` names the build that made the link; the page is the same without it.
        inner.queryItems = nil
        if inner.fragment == nil { inner.fragment = components.fragment }
        self.init(page: inner)
    }

    private init?(page components: URLComponents) {
        guard components.user == nil, components.password == nil, components.port == nil,
              let host = components.host?.lowercased(), Self.hosts.contains(host) else { return nil }
        var parts = components.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 4, parts.last == "" { parts.removeLast() }
        guard parts.count == 3, parts[0].isEmpty, let page = Page(rawValue: parts[1]) else { return nil }
        let fragment = components.fragment.flatMap { $0.isEmpty ? nil : $0 }
        // An invite is joined by account: a fragment on it is not a secret and is dropped.
        self.init(origin: "https://\(host)", page: page, shareID: parts[2], secret: page == .guest ? fragment : nil)
    }

    /// Where the phone's account token is spent for a one-time code on this page.
    public var handoffURL: URL {
        URL(string: "\(origin)/v1/chat-shares/\(shareID)/handoff")!
    }

    /// The page to open: `<origin>/<g|i>/<id>?in_app=1[&cmux_handoff=<code>][#<secret>]`. `in_app=1`
    /// keeps the page from asking the app to open it again; without a code it opens signed out.
    public func pageURL(handoff: String?) -> URL {
        let code = handoff.flatMap { Self.isID($0) ? "&cmux_handoff=\($0)" : nil } ?? ""
        let fragment = secret.map { "#\($0)" } ?? ""
        return URL(string: "\(origin)/\(page.rawValue)/\(shareID)?in_app=1\(code)\(fragment)")!
    }

    /// An id or hand-off code: 16 to 128 URL-safe characters.
    public static func isID(_ text: String) -> Bool {
        (16...128).contains(text.utf8.count) && text.utf8.allSatisfy(isURLSafe)
    }

    static func isSecret(_ text: String) -> Bool {
        (8...128).contains(text.utf8.count) && text.utf8.allSatisfy(isURLSafe)
    }

    private static func isURLSafe(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
    }
}
