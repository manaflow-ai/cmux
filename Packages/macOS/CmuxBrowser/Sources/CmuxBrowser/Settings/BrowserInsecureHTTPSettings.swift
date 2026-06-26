public import Foundation
internal import CmuxCore

/// Reads and edits the persisted allowlist of hosts permitted to load over
/// plaintext `http://`.
///
/// The allowlist is persisted as a delimiter-separated string in `UserDefaults`
/// (under ``allowlistKey``); when empty it falls back to
/// ``defaultAllowlistPatterns`` (loopback and `*.localtest.me` style hosts).
/// Patterns are normalized through ``normalizeHost(_:)`` and matched with
/// support for `*.suffix` wildcards. ``isHostAllowed(_:defaults:)`` answers
/// whether a host may use plaintext HTTP, and ``addAllowedHost(_:defaults:)``
/// appends a host to the stored list.
///
/// Static members only: a wire-affecting `UserDefaults` key, default pattern
/// constants, and pure/stateless allowlist transforms over injected defaults or
/// a raw string, so there is no per-instance state to hold.
/// lint:allow namespace-type — wire-affecting constants plus stateless
/// host-allowlist transforms, no per-instance state (no-namespace-enum carve-out).
public struct BrowserInsecureHTTPSettings {
    /// `UserDefaults` key under which the insecure-HTTP allowlist is persisted.
    public static let allowlistKey = "browserInsecureHTTPAllowlist"

    /// The allowlist patterns applied when nothing valid is stored.
    public static let defaultAllowlistPatterns = [
        "localhost",
        "*.localhost",
        "127.0.0.1",
        "::1",
        "0.0.0.0",
        "*.localtest.me",
    ]

    /// ``defaultAllowlistPatterns`` joined with newlines for text presentation.
    public static let defaultAllowlistText = defaultAllowlistPatterns.joined(separator: "\n")

    /// The normalized allowlist patterns currently in effect.
    ///
    /// - Parameter defaults: The defaults to read the allowlist from.
    /// - Returns: The parsed patterns, or ``defaultAllowlistPatterns`` when
    ///   nothing valid is stored.
    public static func normalizedAllowlistPatterns(defaults: UserDefaults = .standard) -> [String] {
        normalizedAllowlistPatterns(rawValue: defaults.string(forKey: allowlistKey))
    }

    /// The normalized allowlist patterns for a raw stored string.
    ///
    /// - Parameter rawValue: The raw allowlist string, if any.
    /// - Returns: The parsed patterns, or ``defaultAllowlistPatterns`` when
    ///   `rawValue` is empty/blank or parses to nothing.
    public static func normalizedAllowlistPatterns(rawValue: String?) -> [String] {
        let source: String
        if let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source = rawValue
        } else {
            source = defaultAllowlistText
        }
        let parsed = parsePatterns(from: source)
        return parsed.isEmpty ? defaultAllowlistPatterns : parsed
    }

    /// Whether `host` may load over plaintext HTTP per the stored allowlist.
    ///
    /// - Parameters:
    ///   - host: The candidate host.
    ///   - defaults: The defaults to read the allowlist from.
    /// - Returns: `true` when the normalized host matches an allowlist pattern.
    public static func isHostAllowed(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        isHostAllowed(host, rawAllowlist: defaults.string(forKey: allowlistKey))
    }

    /// Whether `host` may load over plaintext HTTP per a raw allowlist string.
    ///
    /// - Parameters:
    ///   - host: The candidate host.
    ///   - rawAllowlist: The raw allowlist string, if any.
    /// - Returns: `true` when the normalized host matches an allowlist pattern.
    public static func isHostAllowed(_ host: String, rawAllowlist: String?) -> Bool {
        guard let normalizedHost = normalizeHost(host) else { return false }
        return normalizedAllowlistPatterns(rawValue: rawAllowlist).contains { pattern in
            hostMatchesPattern(normalizedHost, pattern: pattern)
        }
    }

    /// Appends `host` to the stored allowlist if not already present.
    ///
    /// - Parameters:
    ///   - host: The host to allow; ignored when it fails to normalize.
    ///   - defaults: The defaults to read and write the allowlist.
    public static func addAllowedHost(_ host: String, defaults: UserDefaults = .standard) {
        guard let normalizedHost = normalizeHost(host) else { return }
        var patterns = normalizedAllowlistPatterns(defaults: defaults)
        guard !patterns.contains(normalizedHost) else { return }
        patterns.append(normalizedHost)
        defaults.set(patterns.joined(separator: "\n"), forKey: allowlistKey)
    }

    // Single source of truth: the host normalizer moved to CmuxCore with the
    // loopback alias lift; this forwards so allowlist semantics stay identical.
    /// Normalizes a host string to its canonical comparison form.
    ///
    /// - Parameter rawHost: The raw host (possibly with scheme, port, or
    ///   trailing dot).
    /// - Returns: The normalized host, or `nil` when it is empty/invalid.
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
