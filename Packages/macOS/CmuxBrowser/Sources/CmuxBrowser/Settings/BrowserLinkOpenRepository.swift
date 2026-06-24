public import Foundation
import CmuxCore

/// Reads the user's browser link-routing preferences from `UserDefaults` and decides whether a
/// given link should open in the in-app cmux browser, be intercepted from a terminal `open`,
/// pass a host whitelist, or be forced to an external browser.
///
/// This replaces the app target's caseless `BrowserLinkOpenSettings` namespace enum (all-`static`
/// `UserDefaults` accessors plus pattern/host parsing helpers) with a value type that takes its
/// `UserDefaults` through the initializer, mirroring ``BrowserAvailabilityRepository``. The
/// `static let` keys and defaults stay byte-identical to the app target so persisted values keep
/// resolving for `@AppStorage`/`UserDefaults` readers.
///
/// The "browser available" gate is delegated to ``BrowserAvailabilityRepository`` (constructed
/// over the same `UserDefaults`), which owns the `browserDisabledOverride` key and default; this
/// preserves the original behavior where every routing decision short-circuits when the browser
/// panel is disabled.
public struct BrowserLinkOpenRepository {
    /// The `UserDefaults` key storing whether clicked terminal links open in the cmux browser.
    public static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    /// The shipped default for opening clicked terminal links in the cmux browser.
    public static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    /// The `UserDefaults` key storing whether sidebar pull-request links open in the cmux browser.
    public static let openSidebarPullRequestLinksInCmuxBrowserKey = "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    /// The shipped default for opening sidebar pull-request links in the cmux browser.
    public static let defaultOpenSidebarPullRequestLinksInCmuxBrowser: Bool = true

    /// The `UserDefaults` key storing whether sidebar port links open in the cmux browser.
    public static let openSidebarPortLinksInCmuxBrowserKey = "browserOpenSidebarPortLinksInCmuxBrowser"
    /// The shipped default for opening sidebar port links in the cmux browser.
    public static let defaultOpenSidebarPortLinksInCmuxBrowser: Bool = true

    /// The `UserDefaults` key storing whether a terminal `open` command is intercepted into the cmux browser.
    public static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    /// The shipped default for intercepting a terminal `open` command into the cmux browser.
    public static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    /// The `UserDefaults` key storing the newline-separated host whitelist.
    public static let browserHostWhitelistKey = "browserHostWhitelist"
    /// The shipped default host whitelist (empty, i.e. allow all).
    public static let defaultBrowserHostWhitelist: String = ""
    /// The `UserDefaults` key storing the newline-separated external-open patterns.
    public static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    /// The shipped default external-open patterns (empty).
    public static let defaultBrowserExternalOpenPatterns: String = ""

    private let defaults: UserDefaults
    private let availability: BrowserAvailabilityRepository

    /// Creates a repository backed by the given `UserDefaults`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.availability = BrowserAvailabilityRepository(defaults: defaults)
    }

    /// Whether clicked terminal links should open in the cmux browser, gated on browser availability.
    public func openTerminalLinksInCmuxBrowser() -> Bool {
        guard availability.isEnabled() else { return false }
        if defaults.object(forKey: Self.openTerminalLinksInCmuxBrowserKey) == nil {
            return Self.defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: Self.openTerminalLinksInCmuxBrowserKey)
    }

    /// Whether sidebar pull-request links should open in the cmux browser, gated on browser availability.
    public func openSidebarPullRequestLinksInCmuxBrowser() -> Bool {
        guard availability.isEnabled() else { return false }
        if defaults.object(forKey: Self.openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return Self.defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: Self.openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    /// Whether sidebar port links should open in the cmux browser, gated on browser availability.
    public func openSidebarPortLinksInCmuxBrowser() -> Bool {
        guard availability.isEnabled() else { return false }
        if defaults.object(forKey: Self.openSidebarPortLinksInCmuxBrowserKey) == nil {
            return Self.defaultOpenSidebarPortLinksInCmuxBrowser
        }
        return defaults.bool(forKey: Self.openSidebarPortLinksInCmuxBrowserKey)
    }

    /// Whether a terminal `open` command is intercepted into the cmux browser, gated on browser
    /// availability. Falls back to the legacy link-click toggle for users who only set that one,
    /// then to ``defaultInterceptTerminalOpenCommandInCmuxBrowser``.
    public func interceptTerminalOpenCommandInCmuxBrowser() -> Bool {
        guard availability.isEnabled() else { return false }
        if defaults.object(forKey: Self.interceptTerminalOpenCommandInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: Self.interceptTerminalOpenCommandInCmuxBrowserKey)
        }

        // Migrate existing behavior for users who only had the link-click toggle.
        if defaults.object(forKey: Self.openTerminalLinksInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: Self.openTerminalLinksInCmuxBrowserKey)
        }

        return Self.defaultInterceptTerminalOpenCommandInCmuxBrowser
    }

    /// The initial value for the terminal-open intercept toggle (same resolution as the live read).
    public func initialInterceptTerminalOpenCommandInCmuxBrowserValue() -> Bool {
        interceptTerminalOpenCommandInCmuxBrowser()
    }

    /// The configured host whitelist, parsed from newline-separated entries with whitespace trimmed
    /// and empty lines dropped.
    public func hostWhitelist() -> [String] {
        let raw = defaults.string(forKey: Self.browserHostWhitelistKey) ?? Self.defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The configured external-open patterns, parsed from newline-separated entries with whitespace
    /// trimmed and empty/comment (`#`-prefixed) lines dropped.
    public func externalOpenPatterns() -> [String] {
        let raw = defaults.string(forKey: Self.browserExternalOpenPatternsKey) ?? Self.defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whether the given URL should be forced to open in an external browser.
    public func shouldOpenExternally(_ url: URL) -> Bool {
        shouldOpenExternally(url.absoluteString)
    }

    /// Whether the given raw URL string should be forced to open in an external browser. When the
    /// browser panel is disabled, everything opens externally.
    public func shouldOpenExternally(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        guard availability.isEnabled() else { return true }

        for rawPattern in externalOpenPatterns() {
            guard let (isRegex, value) = Self.parseExternalPattern(rawPattern) else { continue }
            if isRegex {
                guard let regex = try? NSRegularExpression(pattern: value, options: [.caseInsensitive]) else { continue }
                let range = NSRange(target.startIndex..<target.endIndex, in: target)
                if regex.firstMatch(in: target, options: [], range: range) != nil {
                    return true
                }
            } else if target.range(of: value, options: [.caseInsensitive]) != nil {
                return true
            }
        }

        return false
    }

    /// Check whether a hostname matches the configured whitelist.
    /// Empty whitelist means "allow all" (no filtering).
    /// Supports exact match and wildcard prefix (`*.example.com`).
    public func hostMatchesWhitelist(_ host: String) -> Bool {
        let rawPatterns = hostWhitelist()
        if rawPatterns.isEmpty { return true }
        guard let normalizedHost = RemoteLoopbackProxyAlias.normalizeHost(host) else { return false }
        for rawPattern in rawPatterns {
            guard let pattern = Self.normalizeWhitelistPattern(rawPattern) else { continue }
            if Self.hostMatchesPattern(normalizedHost, pattern: pattern) {
                return true
            }
        }
        return false
    }

    private static func normalizeWhitelistPattern(_ rawPattern: String) -> String? {
        let trimmed = rawPattern
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("*.") {
            let suffixRaw = String(trimmed.dropFirst(2))
            guard let suffix = RemoteLoopbackProxyAlias.normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return RemoteLoopbackProxyAlias.normalizeHost(trimmed)
    }

    private static func hostMatchesPattern(_ host: String, pattern: String) -> Bool {
        if pattern.hasPrefix("*.") {
            let suffix = String(pattern.dropFirst(2))
            return host == suffix || host.hasSuffix(".\(suffix)")
        }
        return host == pattern
    }

    private static func parseExternalPattern(_ rawPattern: String) -> (isRegex: Bool, value: String)? {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.lowercased().hasPrefix("re:") {
            let regexPattern = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !regexPattern.isEmpty else { return nil }
            return (isRegex: true, value: regexPattern)
        }

        return (isRegex: false, value: trimmed)
    }
}
