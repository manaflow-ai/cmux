public import Foundation

nonisolated extension DeepLink {
    /// The link `url` names, when it is one in `scheme`.
    ///
    /// Nil for another scheme (another build's links are not opened here),
    /// the `auth-callback` host, an unknown host, a malformed id, extra path
    /// segments, a user, password or port, and a fragment other than a
    /// session's `#turn-<turnId>`. Query parameters other than `machine`, the
    /// legacy `stable_*_id` fallbacks and an agent link's `host`, `name` and
    /// `message` are ignored; an agent link's parameter cmux cannot use is
    /// dropped, and ``read(_:scheme:)`` names it.
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link, or nil when `url` is not one.
    public static func parse(_ url: URL, scheme: String) -> DeepLink? {
        read(url, scheme: scheme)?.link
    }

    /// A link and the parameters it carried that cmux did not use.
    public nonisolated struct Parsed: Sendable, Hashable {
        /// The link itself.
        public var link: DeepLink
        /// Names, never values, of the parameters cmux ignored: ones no link of
        /// that kind reads, and (an agent link) one that is repeated or whose
        /// value is outside its charset. An ignored name never costs the link
        /// its target, so one stray parameter cannot drop a session; a caller
        /// that can say so shows them.
        public var ignoredParameters: [String]

        public init(link: DeepLink, ignoredParameters: [String] = []) {
            self.link = link
            self.ignoredParameters = ignoredParameters
        }
    }

    /// ``parse(_:scheme:)``, with the names of the parameters it ignored
    /// (schemas/deeplinks/agent-link.json).
    ///
    /// - Parameters:
    ///   - url: The URL to read.
    ///   - scheme: The running build's scheme; compared case-insensitively.
    /// - Returns: The link and what it ignored, or nil when `url` is not a link.
    public static func read(_ url: URL, scheme: String) -> Parsed? {
        guard let reply = RustDeepLink.call(["op": "read", "url": url.absoluteString, "scheme": scheme]) as? [String: Any],
              let link = reply["link"].flatMap(RustDeepLink.decode) else { return nil }
        return Parsed(link: link, ignoredParameters: reply["ignoredParameters"] as? [String] ?? [])
    }

    /// The query parameters a link of this kind reads; every other name is
    /// ignored, so a link never carries a command.
    static func parameters(of target: Target) -> Set<String> {
        Set(RustDeepLink.call(["op": "parameters", "target": RustDeepLink.encode(target)]) as? [String] ?? [])
    }

    /// The hosts that serve a cloud group's https hand-off page (`GET /g/<id>[/w/<ws_>]`): the
    /// cmux Cloud API Worker (production and staging) and cmux.com.
    public static let groupWebHosts: Set<String> = ["cloud-api.cmux.dev", "cloud-api-staging.cmux.dev", "cmux.com", "www.cmux.com"]

    /// The cloud group link an https URL names (`https://cloud-api.cmux.dev/g/grp_…`, optionally
    /// `/w/ws_…`), so a click on the web form in the app opens it here, not in a browser.
    ///
    /// - Parameter url: The URL to read.
    /// - Returns: The group link, or nil for any other URL (another host, a port, a user, a
    ///   query, a fragment, or a malformed id).
    public static func parseGroupWeb(_ url: URL) -> DeepLink? {
        RustDeepLink.link(["op": "groupWeb", "url": url.absoluteString])
    }
}
