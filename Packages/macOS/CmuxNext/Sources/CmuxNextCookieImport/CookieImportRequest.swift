import Foundation

/// What the consent panel shows for one agent's cookie import (a value: the
/// panel holds no store). The requester is a reference to the agent (its chat
/// or terminal tab, by name), never a link: a click reveals that tab in cmux.
struct CookieImportRequest: Sendable, Equatable {
    var requester: CookieImportRequester
    /// The agent's own words (`--reason`), shown as given.
    var reason: String
    /// "Google Chrome · Work".
    var source: String
    /// Whether the source is Safari (Full Disk Access instead of a Keychain prompt).
    var sourceIsSafari: Bool
    /// The `--domain` hosts; empty means every cookie of the profile.
    var domains: [String]
    /// The cmux browser profile the cookies go into, by name.
    var target: String
}
