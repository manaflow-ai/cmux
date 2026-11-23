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
        DeepLinkRust.optional(.init("parse", url: url, scheme: scheme), as: DeepLink.self)
    }

    /// A link and the parameters it carried that cmux did not use.
    public nonisolated struct Parsed: Sendable, Hashable, Codable {
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
        DeepLinkRust.optional(.init("read", url: url, scheme: scheme), as: Parsed.self)
    }

    /// The query parameters a link of this kind reads; every other name is
    /// ignored, so a link never carries a command.
    static func parameters(of target: Target) -> Set<String> {
        Set(DeepLinkRust.call(.init("parameters", target: target), as: [String].self) ?? [])
    }

    /// The cloud group link an https URL names (`https://cloud-api.cmux.dev/g/grp_…`, optionally
    /// `/w/ws_…`, on the Cloud API Worker's hosts or cmux.com), so a click on the web form in the
    /// app opens it here, not in a browser.
    ///
    /// - Parameter url: The URL to read.
    /// - Returns: The group link, or nil for any other URL (another host, a port, a user, a
    ///   query, a fragment, or a malformed id).
    public static func parseGroupWeb(_ url: URL) -> DeepLink? {
        DeepLinkRust.optional(.init("groupWeb", url: url), as: DeepLink.self)
    }
}
