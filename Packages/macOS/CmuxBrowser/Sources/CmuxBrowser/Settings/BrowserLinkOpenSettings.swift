public import Foundation

/// Reads the persisted policy for which links and `open` commands route into
/// the embedded cmux browser, plus the host whitelist and external-open
/// patterns that override that routing.
///
/// Each toggle is persisted under its own `UserDefaults` key with a matching
/// default, and every read is gated by ``BrowserAvailabilitySettings`` so a
/// disabled browser never captures links. ``shouldOpenExternally(_:defaults:)``
/// matches a URL against the user's external-open patterns (substring or `re:`
/// regex), ``hostMatchesWhitelist(_:defaults:)`` enforces the optional host
/// whitelist, and ``interceptTerminalOpenCommandInCmuxBrowser(defaults:)``
/// migrates the legacy link-click toggle for users who only had that one.
///
/// Static members only: wire-affecting `UserDefaults` keys, defaults, and pure
/// stateless policy transforms over injected defaults, so there is no
/// per-instance state to hold (one-line justification per the no-namespace-enum
/// convention). lint:allow namespace-type — wire-affecting constants plus
/// stateless link-routing policy transforms, no per-instance state.
public struct BrowserLinkOpenSettings {
    /// `UserDefaults` key for routing clicked terminal links into the browser.
    public static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    /// Default for ``openTerminalLinksInCmuxBrowserKey``.
    public static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    /// `UserDefaults` key for routing sidebar pull-request links into the browser.
    public static let openSidebarPullRequestLinksInCmuxBrowserKey = "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    /// Default for ``openSidebarPullRequestLinksInCmuxBrowserKey``.
    public static let defaultOpenSidebarPullRequestLinksInCmuxBrowser: Bool = true

    /// `UserDefaults` key for routing sidebar port links into the browser.
    public static let openSidebarPortLinksInCmuxBrowserKey = "browserOpenSidebarPortLinksInCmuxBrowser"
    /// Default for ``openSidebarPortLinksInCmuxBrowserKey``.
    public static let defaultOpenSidebarPortLinksInCmuxBrowser: Bool = true

    /// `UserDefaults` key for intercepting the terminal `open` command.
    public static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    /// Default for ``interceptTerminalOpenCommandInCmuxBrowserKey``.
    public static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    /// `UserDefaults` key for the newline-separated host whitelist.
    public static let browserHostWhitelistKey = "browserHostWhitelist"
    /// Default for ``browserHostWhitelistKey`` (empty means "allow all").
    public static let defaultBrowserHostWhitelist: String = ""
    /// `UserDefaults` key for the newline-separated external-open patterns.
    public static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    /// Default for ``browserExternalOpenPatternsKey``.
    public static let defaultBrowserExternalOpenPatterns: String = ""

    /// Whether clicked terminal links open in the cmux browser.
    ///
    /// - Parameter defaults: The defaults to read the toggle from.
    /// - Returns: `false` when the browser is disabled, otherwise the stored
    ///   value (or ``defaultOpenTerminalLinksInCmuxBrowser`` when unset).
    public static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    /// Whether sidebar pull-request links open in the cmux browser.
    ///
    /// - Parameter defaults: The defaults to read the toggle from.
    /// - Returns: `false` when the browser is disabled, otherwise the stored
    ///   value (or ``defaultOpenSidebarPullRequestLinksInCmuxBrowser`` when unset).
    public static func openSidebarPullRequestLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    /// Whether sidebar port links open in the cmux browser.
    ///
    /// - Parameter defaults: The defaults to read the toggle from.
    /// - Returns: `false` when the browser is disabled, otherwise the stored
    ///   value (or ``defaultOpenSidebarPortLinksInCmuxBrowser`` when unset).
    public static func openSidebarPortLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPortLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPortLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPortLinksInCmuxBrowserKey)
    }

    /// Whether the terminal `open` command is intercepted into the cmux browser.
    ///
    /// - Parameter defaults: The defaults to read the toggle from.
    /// - Returns: `false` when the browser is disabled; otherwise the stored
    ///   value, falling back to the legacy link-click toggle and then
    ///   ``defaultInterceptTerminalOpenCommandInCmuxBrowser``.
    public static func interceptTerminalOpenCommandInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: interceptTerminalOpenCommandInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: interceptTerminalOpenCommandInCmuxBrowserKey)
        }

        // Migrate existing behavior for users who only had the link-click toggle.
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) != nil {
            return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
        }

        return defaultInterceptTerminalOpenCommandInCmuxBrowser
    }

    /// The initial value for the terminal `open`-intercept toggle.
    ///
    /// - Parameter defaults: The defaults to read the toggle from.
    /// - Returns: The resolved ``interceptTerminalOpenCommandInCmuxBrowser(defaults:)``.
    public static func initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: UserDefaults = .standard) -> Bool {
        interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults)
    }

    /// The configured host whitelist, trimmed and non-empty.
    ///
    /// - Parameter defaults: The defaults to read the whitelist from.
    /// - Returns: The whitelist entries (empty means "allow all").
    public static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The configured external-open patterns, trimmed, non-empty, and
    /// comment-stripped (`#` prefix).
    ///
    /// - Parameter defaults: The defaults to read the patterns from.
    /// - Returns: The pattern entries.
    public static func externalOpenPatterns(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserExternalOpenPatternsKey) ?? defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Whether `url` should open externally (outside the cmux browser).
    ///
    /// - Parameters:
    ///   - url: The candidate URL.
    ///   - defaults: The defaults to read the patterns from.
    /// - Returns: `true` when the URL matches an external-open pattern.
    public static func shouldOpenExternally(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldOpenExternally(url.absoluteString, defaults: defaults)
    }

    /// Whether `rawURL` should open externally (outside the cmux browser).
    ///
    /// - Parameters:
    ///   - rawURL: The candidate URL string.
    ///   - defaults: The defaults to read the patterns from.
    /// - Returns: `true` when the URL matches an external-open pattern; `true`
    ///   when the browser is disabled; `false` for an empty input.
    public static func shouldOpenExternally(_ rawURL: String, defaults: UserDefaults = .standard) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return true }

        for rawPattern in externalOpenPatterns(defaults: defaults) {
            guard let (isRegex, value) = parseExternalPattern(rawPattern) else { continue }
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
    public static func hostMatchesWhitelist(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        let rawPatterns = hostWhitelist(defaults: defaults)
        if rawPatterns.isEmpty { return true }
        guard let normalizedHost = BrowserInsecureHTTPSettings.normalizeHost(host) else { return false }
        for rawPattern in rawPatterns {
            guard let pattern = normalizeWhitelistPattern(rawPattern) else { continue }
            if hostMatchesPattern(normalizedHost, pattern: pattern) {
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
            guard let suffix = BrowserInsecureHTTPSettings.normalizeHost(suffixRaw) else { return nil }
            return "*.\(suffix)"
        }

        return BrowserInsecureHTTPSettings.normalizeHost(trimmed)
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
