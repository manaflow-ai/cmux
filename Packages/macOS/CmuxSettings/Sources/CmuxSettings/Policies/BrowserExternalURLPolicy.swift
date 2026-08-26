import Foundation

/// Matches configured URL rules that should bypass the embedded browser.
///
/// Rules are stored as one string per line by the legacy settings surface, but
/// the JSON settings importer and older releases can leave them as an array in
/// `UserDefaults`. The policy accepts both representations so every browser
/// entry point evaluates the same effective rules.
public struct BrowserExternalURLPolicy: Equatable, Sendable {
    /// The legacy `UserDefaults` key used by the browser settings catalog.
    public static let userDefaultsKey = "browserExternalOpenPatterns"

    /// The normalized, non-empty rules used by this policy.
    public let patterns: [String]

    private let matcher: BrowserExternalURLPatternMatcher

    /// Creates a policy from a `UserDefaults` suite.
    ///
    /// - Parameter defaults: The preference suite containing the browser rules.
    public init(defaults: UserDefaults) {
        self.init(rawValue: defaults.object(forKey: Self.userDefaultsKey))
    }

    /// Creates a policy from explicit rule values.
    ///
    /// - Parameter patterns: Rules in either line-oriented or array form.
    public init(patterns: [String]) {
        let matcher = BrowserExternalURLPatternMatcher()
        self.matcher = matcher
        self.patterns = matcher.normalizedPatterns(from: patterns)
    }

    private init(rawValue: Any?) {
        let matcher = BrowserExternalURLPatternMatcher()
        self.matcher = matcher
        self.patterns = matcher.normalizedPatterns(from: matcher.stringValues(from: rawValue))
    }

    /// Returns whether a URL matches at least one configured rule.
    public func matches(_ url: URL) -> Bool {
        matches(url.absoluteString)
    }

    /// Returns whether raw URL text matches at least one configured rule.
    public func matches(_ rawURL: String) -> Bool {
        let target = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }

        return patterns.contains { pattern in
            matcher.matches(pattern: pattern, target: target)
        }
    }
}
