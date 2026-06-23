public import Foundation
public import AppKit
import CmuxCore

/// Reads and writes the insecure-HTTP allowlist and decides whether a plain
/// HTTP navigation is blocked, bypassed once, or persisted to the allowlist.
///
/// This replaces the app target's caseless `BrowserInsecureHTTPSettings`
/// namespace enum (all-`static` `UserDefaults` accessors plus the four
/// file-scope `browserShould…` free functions) with a value type that takes its
/// `UserDefaults` through the initializer, mirroring the other `CmuxBrowser`
/// `Import` repositories (``BrowserImportHintRepository``). The `static let`
/// keys and shipped defaults stay byte-identical to the app target so the
/// stored allowlist and the running browser agree.
///
/// Host normalization and loopback classification are delegated to
/// ``RemoteLoopbackProxyAlias`` in `CmuxCore` so there is a single source of
/// truth for the wire-affecting host transforms shared with the proxy path.
public struct BrowserInsecureHTTPRepository {
    /// The `UserDefaults` key storing the newline/comma-separated allowlist text.
    /// Wire/persisted value: do not rename.
    public static let allowlistKey = "browserInsecureHTTPAllowlist"

    /// The shipped allowlist patterns used when no value is stored.
    public static let defaultAllowlistPatterns = [
        "localhost",
        "*.localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]

    /// The shipped allowlist patterns joined into the stored text form.
    public static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    private let defaults: UserDefaults

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Allowlist

    /// The normalized allowlist patterns for the currently stored text.
    public func normalizedAllowlistPatterns() -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: Self.allowlistKey))
    }

    /// The normalized allowlist patterns for an explicit raw text value,
    /// falling back to the shipped defaults when the value is missing or blank.
    public func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        let source: String
        if let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = rawValue
        } else {
            source = Self.defaultAllowlistText
        }
        let parsed = Self.parsePatterns(from: source)
        return parsed.isEmpty ? Self.defaultAllowlistPatterns : parsed
    }

    /// Whether `host` is allowed by the currently stored allowlist.
    public func isHostAllowed(_ host: String) -> Bool {
        isHostAllowed(host, rawAllowlist: defaults.string(forKey: Self.allowlistKey))
    }

    /// Whether `host` is allowed by an explicit raw allowlist text value.
    public func isHostAllowed(_ host: String, rawAllowlist: String?) -> Bool {
        guard let normalizedHost = Self.normalizeHost(host) else { return false }
        return normalizedAllowlistPatterns(rawValue: rawAllowlist).contains { pattern in
            Self.hostMatchesPattern(normalizedHost, pattern: pattern)
        }
    }

    /// Appends `host` to the stored allowlist if it normalizes and is not
    /// already present.
    public func addAllowedHost(_ host: String) {
        guard let normalizedHost = Self.normalizeHost(host) else { return }
        var patterns = normalizedAllowlistPatterns()
        guard !patterns.contains(normalizedHost) else { return }
        patterns.append(normalizedHost)
        defaults.set(patterns.joined(separator: "\n"), forKey: Self.allowlistKey)
    }

    // MARK: - Navigation policy

    /// Whether a plain HTTP navigation to `url` is blocked by the currently
    /// stored allowlist. HTTPS (and any non-`http` scheme) is never blocked.
    public func shouldBlock(_ url: URL) -> Bool {
        shouldBlock(url, rawAllowlist: defaults.string(forKey: Self.allowlistKey))
    }

    /// Whether a plain HTTP navigation to `url` is blocked by an explicit raw
    /// allowlist text value.
    public func shouldBlock(_ url: URL, rawAllowlist: String?) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        guard let host = Self.normalizeHost(url.host ?? "") else { return true }
        return !isHostAllowed(host, rawAllowlist: rawAllowlist)
    }

    /// Consumes a one-shot bypass for `url`'s host, returning `true` (and
    /// clearing the bypass) when the pending host matches. Lets a single
    /// post-prompt navigation proceed without re-prompting.
    public func consumeOneTimeBypass(_ url: URL, bypassHostOnce: inout String?) -> Bool {
        guard let bypassHost = bypassHostOnce else { return false }
        guard url.scheme?.lowercased() == "http",
              let host = Self.normalizeHost(url.host ?? "") else {
            return false
        }
        guard host == bypassHost else { return false }
        bypassHostOnce = nil
        return true
    }

    /// Whether the user's modal response (with the suppression checkbox on)
    /// should persist the host to the allowlist. "Open in default browser" and
    /// "Proceed in cmux" both persist; "Cancel" does not.
    public func shouldPersistAllowlistSelection(
        response: NSApplication.ModalResponse,
        suppressionEnabled: Bool
    ) -> Bool {
        guard suppressionEnabled else { return false }
        return response == .alertFirstButtonReturn || response == .alertSecondButtonReturn
    }

    // MARK: - Host transforms

    /// Normalizes a raw host string to a bare lowercase host for comparison.
    ///
    /// Single source of truth: the host normalizer lives in
    /// ``RemoteLoopbackProxyAlias`` with the loopback alias lift; this forwards
    /// so allowlist semantics stay identical.
    public static func normalizeHost(_ rawHost: String) -> String? {
        RemoteLoopbackProxyAlias.normalizeHost(rawHost)
    }

    private static func parsePatterns(from rawValue: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t")
        var out: [String] = []
        var seen = Set<String>()
        for token in rawValue.components(separatedBy: separators) {
            guard let normalized = normalizePattern(token) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            out.append(normalized)
        }
        return out
    }

    private static func normalizePattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }
}
