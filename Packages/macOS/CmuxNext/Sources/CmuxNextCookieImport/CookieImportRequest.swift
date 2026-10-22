import Foundation

/// What the permission card shows for one agent's cookie import (a value: the card holds no
/// store). The requester is a reference to the agent (its chat, its Chief or its terminal tab, by
/// name), never a link: a click reveals that tab in cmux. The reason and sites are already made
/// safe to show (``CookieImportText``).
public struct CookieImportRequest: Sendable, Equatable {
    /// Who asked.
    public var requester: CookieImportRequester
    /// The agent's own words (`--reason`), shown as given once made safe.
    public var reason: String
    /// "Google Chrome · Work".
    public var source: String
    /// What macOS asks after Allow.
    public var prompt: Prompt
    /// The `--domain` sites in ASCII; empty means every cookie of the profile.
    public var domains: [String]
    /// The cmux browser profile the cookies go into, by name.
    public var target: String

    /// What the person meets after Allow, before anything is read.
    public enum Prompt: Sendable, Equatable {
        /// macOS asks for the login password to give cmux the browser's Safe Storage key
        /// (`Chrome Safe Storage`); the associated value is the browser's name.
        case keychain(service: String)
        /// cmux needs Full Disk Access (Safari's cookies sit in its container).
        case fullDiskAccess
        /// Nothing more (Firefox keeps its cookies in plain files).
        case none
    }

    /// Creates a request.
    public init(requester: CookieImportRequester, reason: String, source: String, prompt: Prompt, domains: [String], target: String) {
        self.requester = requester
        self.reason = reason
        self.source = source
        self.prompt = prompt
        self.domains = domains
        self.target = target
    }

    /// Whether the request reaches every site of the profile (the card warns).
    public var isEverySite: Bool { domains.isEmpty }
}
