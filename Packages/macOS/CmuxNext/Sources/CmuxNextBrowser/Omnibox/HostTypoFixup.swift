import Foundation
import CmuxNextCompat

/// Fixes a mistyped top-level domain in text the user typed into the
/// address bar or the palette (`example.con` loads `example.com`), with
/// Firefox's table (`URIFixup.sys.mjs`, `fixupTypos`).
///
/// Only the host's last label changes; scheme, port, path, query and
/// fragment stay as typed. Nothing changes when the last label is a real
/// top-level domain (`TopLevelDomains`), the host ends with an explicit
/// dot, the host is an IP literal or a single label (`localhost`), the
/// text has userinfo, whitespace or a scheme other than http(s), or the
/// text is a file path. Callers apply it only to typed text: never to
/// pasted text, clicked links, bookmarks, history rows or agent input.
nonisolated enum HostTypoFixup {
    struct Fix: Equatable, Sendable, Decodable {
        /// The typed text with the last host label replaced.
        var text: String
        /// The host as typed, lowercased (`example.con`).
        var typedHost: String
    }

    /// The fixed text, or nil when `text` has nothing to fix (cmux-browser-rules
    /// `fix_host_typo`, with Firefox's typo table and its tests).
    static func fix(_ text: String) -> Fix? {
        BrowserRules.call("browser_rules_host_typo_fix", ["text": text], as: Fix?.self) ?? nil
    }
}

/// The IANA root zone's top-level domains (cmux-browser-rules `data/top-level-domains.txt`,
/// https://data.iana.org/TLD/tlds-alpha-by-domain.txt). These are the public suffix list's
/// top-level entries: a label not in it cannot resolve on the public internet.
nonisolated enum TopLevelDomains {
    /// `label` (any case, ASCII or punycode) is a delegated top-level domain.
    static func contains(_ label: String) -> Bool {
        BrowserRules.call("browser_rules_is_top_level_domain", ["label": label], as: Bool.self) ?? false
    }
}

public extension String {
    /// This label (any case, ASCII or punycode) is a delegated top-level domain (``TopLevelDomains``).
    nonisolated var isTopLevelDomain: Bool { TopLevelDomains.contains(self) }
}

/// Typed hosts the omnibar already fixed. Typing one again means the user
/// wants that host, so it is not fixed a second time. One per suggestion
/// engine (per browser profile; incognito has its own), in memory only.
public nonisolated final class HostTypoMemory: Sendable {
    private let fixed = Mutex<Set<String>>([])

    public init() {}

    public func allowsFix(of typedHost: String) -> Bool {
        fixed.withLock { !$0.contains(typedHost.lowercased()) }
    }

    public func recordFix(of typedHost: String) {
        _ = fixed.withLock { $0.insert(typedHost.lowercased()) }
    }
}
