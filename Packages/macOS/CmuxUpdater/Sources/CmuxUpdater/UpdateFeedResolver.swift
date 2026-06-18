import Foundation

/// Resolves which Sparkle appcast feed URL the updater should use, given the URL baked
/// into the app's `Info.plist` at build time.
///
/// Stable releases ship with the stable appcast URL and `cmux NIGHTLY` has the nightly
/// appcast URL injected by CI. When the `Info.plist` value is missing or empty the resolver
/// falls back to the latest-release appcast so the updater still has a feed to query.
///
/// ```swift
/// let resolver = UpdateFeedResolver()
/// let resolution = resolver.resolve(infoFeedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)
/// updater.setFeedURL(resolution.url)
/// ```
public struct UpdateFeedResolver: Sendable {
    /// The outcome of resolving a feed URL: the URL to use plus how it was classified.
    public struct Resolution: Equatable, Sendable {
        /// The feed URL the updater should query.
        public let url: String
        /// Whether `url` points at the nightly channel (its path contains `/nightly/`).
        public let isNightly: Bool
        /// Whether `url` came from ``UpdateFeedResolver/fallbackFeedURL`` because the
        /// `Info.plist` feed URL was missing or empty.
        public let usedFallback: Bool

        /// Creates a resolution result.
        public init(url: String, isNightly: Bool, usedFallback: Bool) {
            self.url = url
            self.isNightly = isNightly
            self.usedFallback = usedFallback
        }
    }

    /// The appcast URL used when the `Info.plist` feed URL is missing or empty.
    public let fallbackFeedURL: String

    /// Creates a resolver.
    ///
    /// - Parameter fallbackFeedURL: The appcast URL to fall back to when the build-time
    ///   feed URL is absent. Defaults to the project's latest-release appcast.
    public init(fallbackFeedURL: String = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml") {
        self.fallbackFeedURL = fallbackFeedURL
    }

    /// Resolves the feed URL to use.
    ///
    /// - Parameter infoFeedURL: The `SUFeedURL` value from the app's `Info.plist`, if any.
    /// - Returns: The resolved URL plus whether it is the nightly channel and whether the
    ///   fallback was used.
    public func resolve(infoFeedURL: String?) -> Resolution {
        guard let infoFeedURL, !infoFeedURL.isEmpty else {
            return Resolution(url: fallbackFeedURL, isNightly: false, usedFallback: true)
        }
        return Resolution(url: infoFeedURL, isNightly: infoFeedURL.contains("/nightly/"), usedFallback: false)
    }
}
