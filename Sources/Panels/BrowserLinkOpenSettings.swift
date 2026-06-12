import Foundation
import Combine
import WebKit
import AppKit
import Bonsplit
import Network
import CFNetwork
import SQLite3
import CryptoKit
import Darwin
#if canImport(CommonCrypto)
import CommonCrypto
#endif
#if canImport(Security)
import Security
#endif


// MARK: - Link open & availability settings
enum BrowserLinkOpenSettings {
    static let openTerminalLinksInCmuxBrowserKey = "browserOpenTerminalLinksInCmuxBrowser"
    static let defaultOpenTerminalLinksInCmuxBrowser: Bool = true

    static let openSidebarPullRequestLinksInCmuxBrowserKey = "browserOpenSidebarPullRequestLinksInCmuxBrowser"
    static let defaultOpenSidebarPullRequestLinksInCmuxBrowser: Bool = true

    static let openSidebarPortLinksInCmuxBrowserKey = "browserOpenSidebarPortLinksInCmuxBrowser"
    static let defaultOpenSidebarPortLinksInCmuxBrowser: Bool = true

    static let interceptTerminalOpenCommandInCmuxBrowserKey = "browserInterceptTerminalOpenCommandInCmuxBrowser"
    static let defaultInterceptTerminalOpenCommandInCmuxBrowser: Bool = true

    static let browserHostWhitelistKey = "browserHostWhitelist"
    private static let defaultBrowserHostWhitelist: String = ""
    static let browserExternalOpenPatternsKey = "browserExternalOpenPatterns"
    private static let defaultBrowserExternalOpenPatterns: String = ""

    static func openTerminalLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openTerminalLinksInCmuxBrowserKey) == nil {
            return defaultOpenTerminalLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openTerminalLinksInCmuxBrowserKey)
    }

    static func openSidebarPullRequestLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPullRequestLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPullRequestLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPullRequestLinksInCmuxBrowserKey)
    }

    static func openSidebarPortLinksInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
        guard BrowserAvailabilitySettings.isEnabled(defaults: defaults) else { return false }
        if defaults.object(forKey: openSidebarPortLinksInCmuxBrowserKey) == nil {
            return defaultOpenSidebarPortLinksInCmuxBrowser
        }
        return defaults.bool(forKey: openSidebarPortLinksInCmuxBrowserKey)
    }

    static func interceptTerminalOpenCommandInCmuxBrowser(defaults: UserDefaults = .standard) -> Bool {
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

    static func initialInterceptTerminalOpenCommandInCmuxBrowserValue(defaults: UserDefaults = .standard) -> Bool {
        interceptTerminalOpenCommandInCmuxBrowser(defaults: defaults)
    }

    static func hostWhitelist(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserHostWhitelistKey) ?? defaultBrowserHostWhitelist
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func externalOpenPatterns(defaults: UserDefaults = .standard) -> [String] {
        let raw = defaults.string(forKey: browserExternalOpenPatternsKey) ?? defaultBrowserExternalOpenPatterns
        return raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func shouldOpenExternally(_ url: URL, defaults: UserDefaults = .standard) -> Bool {
        shouldOpenExternally(url.absoluteString, defaults: defaults)
    }

    static func shouldOpenExternally(_ rawURL: String, defaults: UserDefaults = .standard) -> Bool {
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
    static func hostMatchesWhitelist(_ host: String, defaults: UserDefaults = .standard) -> Bool {
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

enum BrowserAvailabilitySettings {
    static let disabledKey = "browserDisabledOverride"
    static let didChangeNotification = Notification.Name("cmux.browserAvailabilityDidChange")
    private static let defaultDisabled = false

    static func isDisabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.synchronize()
        if defaults.object(forKey: disabledKey) == nil {
            return defaultDisabled
        }
        return defaults.bool(forKey: disabledKey)
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        !isDisabled(defaults: defaults)
    }

    static func setDisabled(_ disabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(disabled, forKey: disabledKey)
        defaults.synchronize()
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}

