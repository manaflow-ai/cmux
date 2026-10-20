import Foundation

/// The Public Suffix List (`Resources/PublicSuffixList.dat`, publicsuffix.org,
/// MPL-2.0; the same rules `backend/scripts/update-public-suffix.ts` writes)
/// and its registrable-domain ("eTLD+1") algorithm. Email verification
/// AutoFill uses it for a security decision (which page may see an email's
/// code), so unlike ``SiteDomain`` it has the full list, private section
/// included: `someone.github.io` is its own site.
///
/// It fails closed: a host it cannot read with certainty (non-ASCII, an IP
/// literal, an empty label) has no registrable domain, so nothing matches it.
///
/// ```swift
/// let list = PublicSuffixList(listText: "com\nco.uk\n")
/// list.registrableDomain(of: "accounts.github.com") // "github.com"
/// list.registrableDomain(of: "co.uk")               // nil
/// ```
public nonisolated struct PublicSuffixList: Sendable {
    private let exact: Set<String>
    private let wildcard: Set<String>
    private let exception: Set<String>

    /// Reads a list in the publicsuffix.org text format: one rule per line,
    /// `//` comments, `*.` wildcards, `!` exceptions, IDN rules in punycode.
    /// - Parameter listText: The list's text.
    public init(listText: String) {
        var exact = Set<String>(), wildcard = Set<String>(), exception = Set<String>()
        for line in listText.split(whereSeparator: \.isNewline) {
            guard let rule = line.split(whereSeparator: \.isWhitespace).first?.lowercased(),
                  !rule.hasPrefix("//") else { continue }
            if rule.hasPrefix("!") {
                exception.insert(String(rule.dropFirst()))
            } else if rule.hasPrefix("*.") {
                wildcard.insert(String(rule.dropFirst(2)))
            } else {
                exact.insert(rule)
            }
        }
        self.exact = exact
        self.wildcard = wildcard
        self.exception = exception
    }

    /// The list bundled with the app, or nil when the resource is missing
    /// (then email verification AutoFill offers nothing). Reads a ~200 KB
    /// file: build it once per owner, off the typing path.
    public static func bundled() -> PublicSuffixList? {
        guard let url = Bundle.module.url(forResource: "PublicSuffixList", withExtension: "dat"),
              // concurrency-allow: a bundled file read once when email verification AutoFill turns on.
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return PublicSuffixList(listText: text)
    }

    /// How many rules the list holds.
    public var ruleCount: Int { exact.count + wildcard.count + exception.count }

    /// The registrable domain of `host`: its public suffix plus one label,
    /// lowercased. Nil for a public suffix itself, a single label, an IP
    /// literal, a non-ASCII host (pass punycode), a malformed host, or any
    /// host when the list is empty.
    /// - Parameter host: A host name, any case, with or without a trailing dot.
    /// - Returns: The registrable domain, or nil.
    public func registrableDomain(of host: String) -> String? {
        // An empty list (a missing resource) decides nothing: without it "co.uk" would be a site.
        guard ruleCount > 0, let labels = Self.labels(of: host) else { return nil }
        let suffixLength = publicSuffixLength(labels)
        guard labels.count > suffixLength else { return nil }
        return labels.suffix(suffixLength + 1).joined(separator: ".")
    }

    /// The number of trailing labels that form the public suffix: the
    /// longest matching rule, an exception removing its leftmost label, and
    /// the default rule `*` (one label) when nothing matches.
    private func publicSuffixLength(_ labels: [String]) -> Int {
        for start in labels.indices {
            let candidate = labels[start...].joined(separator: ".")
            if exception.contains(candidate) { return labels.count - start - 1 }
            if exact.contains(candidate) { return labels.count - start }
            if start + 1 < labels.count, wildcard.contains(labels[(start + 1)...].joined(separator: ".")) {
                return labels.count - start
            }
        }
        return 1
    }

    /// The host's labels, or nil when the host is not a plain ASCII DNS name.
    private static func labels(of host: String) -> [String]? {
        var name = host.lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty,
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" || $0 == "." })
        else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let last = labels.last, labels.allSatisfy({ !$0.isEmpty }) else { return nil }
        // An all-digit last label is an IPv4 literal, never a domain.
        if last.allSatisfy(\.isNumber) { return nil }
        return labels
    }
}
