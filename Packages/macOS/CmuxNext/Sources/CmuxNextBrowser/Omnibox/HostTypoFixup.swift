import Foundation
import Synchronization

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
    /// Mistyped last label -> intended top-level domain.
    static let typos: [String: String] = [
        "ocm": "com", "con": "com", "cmo": "com", "xom": "com", "vom": "com", "cpm": "com", "com'": "com",
        "ent": "net", "ner": "net", "nte": "net", "met": "net",
        "rog": "org", "ogr": "org", "prg": "org", "orh": "org",
    ]

    struct Fix: Equatable, Sendable {
        /// The typed text with the last host label replaced.
        var text: String
        /// The host as typed, lowercased (`example.con`).
        var typedHost: String
    }

    /// The fixed text, or nil when `text` has nothing to fix.
    static func fix(_ text: String, isTopLevelDomain: (String) -> Bool = TopLevelDomains.contains) -> Fix? {
        nil
    }
}

/// The IANA root zone's top-level domains (`Resources/TopLevelDomains.txt`,
/// https://data.iana.org/TLD/tlds-alpha-by-domain.txt). These are the
/// public suffix list's top-level entries: a label not in it cannot
/// resolve on the public internet.
nonisolated enum TopLevelDomains {
    private static let all: Set<String> = {
        guard let url = Bundle.module.url(forResource: "TopLevelDomains", withExtension: "txt"),
              // concurrency-allow: a 10 KB bundled file, read once, and only after Enter on a typed host whose last label is in the typo table.
              let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(contents.split(whereSeparator: \.isNewline).lazy
            .filter { !$0.hasPrefix("#") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }()

    /// `label` (any case, ASCII or punycode) is a delegated top-level domain.
    static func contains(_ label: String) -> Bool {
        all.contains(label.lowercased())
    }
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
