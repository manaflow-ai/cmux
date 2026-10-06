public import Foundation

/// Sites (registrable domains) by the Public Suffix List macOS keeps in
/// CFNetwork (`_CFHostIsDomainTopLevel`), the list WebKit itself reads for
/// its site boundaries, so the driver's cookie scope and the session's
/// `site` answer match the browser's own notion of a site and follow OS
/// updates. Both the list's ICANN and private sections apply (`github.io`
/// pages are separate sites). The dev backend's stand-in is
/// `tests/browser-parity/lib/public-suffix.mjs`.
public final class BrowserReplPublicSuffixList: Sendable {
    private let lookup: @Sendable (String) -> Bool

    /// Whether the list could be read. Without it no name counts as a
    /// public suffix, so sites are hosts (narrower, never wider), but a
    /// wildcard pattern cannot be told from one over a public suffix and is
    /// refused (``BrowserReplDomainPattern/parse(_:title:publicSuffixes:)``).
    public let isAvailable: Bool

    /// - Parameter isPublicSuffix: Whether a normalized name (`co.uk`) is a
    ///   public suffix.
    public init(isPublicSuffix: @escaping @Sendable (String) -> Bool) {
        self.lookup = isPublicSuffix
        self.isAvailable = true
    }

    private init(unavailable: Void) {
        self.lookup = { _ in false }
        self.isAvailable = false
    }

    /// A list that could not be read.
    public static let unavailable = BrowserReplPublicSuffixList(unavailable: ())

    /// Whether `name` (`com`, `co.uk`, `github.io`) is itself a public
    /// suffix, so a wildcard over it would name every site under it.
    public func isPublicSuffix(_ name: String) -> Bool {
        var trimmed = name.trimmingCharacters(in: .whitespaces)
        while trimmed.hasPrefix(".") { trimmed.removeFirst() }
        let normalized = BrowserReplHostName.normalize(trimmed)
        guard !normalized.isEmpty, !BrowserReplHostName.isOverlong(normalized),
              !BrowserReplHostName.isIPAddress(normalized) else { return false }
        return lookup(normalized)
    }

    /// The system's list. Where CFNetwork does not export it, the list is
    /// ``unavailable``: every host is its own site (a narrower scope, never
    /// a wider one) and wildcard patterns are refused.
    public static let system = SystemPublicSuffixes.isAvailable
        ? BrowserReplPublicSuffixList(isPublicSuffix: SystemPublicSuffixes.contains)
        : .unavailable

    /// The site of `host`: its registrable domain (`x.co.at` for
    /// `a.x.co.at`), or the host itself when it has none: an IP address, a
    /// single label such as `localhost`, a public suffix itself, or a name
    /// under a top-level label the list does not know.
    public func site(of host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        let normalized = BrowserReplHostName.normalize(name)
        // An overlong host is no host name: its own site, not walked.
        guard !normalized.isEmpty, !BrowserReplHostName.isOverlong(normalized),
              !BrowserReplHostName.isIPAddress(normalized) else { return normalized }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count > 1, !labels.contains(where: \.isEmpty) else { return normalized }
        // The longest public suffix wins: walk from the longest parent.
        for start in 0..<(labels.count - 1) where lookup(labels[(start + 1)...].joined(separator: ".")) {
            return labels[start...].joined(separator: ".")
        }
        return normalized
    }
}

/// CFNetwork's Public Suffix List lookup, resolved once.
private enum SystemPublicSuffixes {
    private typealias Lookup = @convention(c) (CFString) -> DarwinBoolean

    private static let lookup: Lookup? = {
        guard let handle = dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_LAZY),
              let symbol = dlsym(handle, "_CFHostIsDomainTopLevel") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static var isAvailable: Bool { lookup != nil }

    static func contains(_ name: String) -> Bool {
        lookup?(name as CFString).boolValue ?? false
    }
}
