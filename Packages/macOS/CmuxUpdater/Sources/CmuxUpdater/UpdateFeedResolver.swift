import Foundation

/// Resolves which Sparkle appcast feed URL the updater should use, given the URL baked
/// into the app's `Info.plist` at build time.
///
/// Stable releases ship with the stable appcast URL and `cmux NIGHTLY` has the nightly
/// appcast URL injected by CI. When the `Info.plist` value is missing or empty the resolver
/// falls back to the latest-release appcast so the updater still has a feed to query.
///
/// Nightly feeds are per architecture. A nightly `appcast.xml` (or the older
/// `appcast-universal.xml`) URL is rewritten to `appcast-arm64.xml` or `appcast-x86_64.xml`
/// for the host machine, so a universal nightly migrates itself onto the thin build and an
/// x86_64 nightly running under Rosetta moves to the native one.
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
    /// The architecture nightly feeds are resolved for.
    public let hostArchitecture: UpdateHostArchitecture

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - fallbackFeedURL: The appcast URL to fall back to when the build-time feed URL is
    ///     absent. Defaults to the project's latest-release appcast.
    ///   - hostArchitecture: The architecture to select nightly feeds for. Defaults to the
    ///     machine's native architecture.
    public init(
        fallbackFeedURL: String = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml",
        hostArchitecture: UpdateHostArchitecture = .current
    ) {
        self.fallbackFeedURL = fallbackFeedURL
        self.hostArchitecture = hostArchitecture
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
        let isNightly = infoFeedURL.contains("/nightly/")
        let url = isNightly ? Self.architectureSpecificNightlyFeedURL(infoFeedURL, architecture: hostArchitecture) : infoFeedURL
        return Resolution(url: url, isNightly: isNightly, usedFallback: false)
    }

    /// Rewrites a nightly feed URL whose file name is the legacy `appcast.xml` or
    /// `appcast-universal.xml` to the per-architecture feed. URLs that already name an
    /// architecture, or use another file name, are returned unchanged.
    static func architectureSpecificNightlyFeedURL(_ feedURL: String, architecture: UpdateHostArchitecture) -> String {
        for legacyName in ["/appcast.xml", "/appcast-universal.xml"] where feedURL.hasSuffix(legacyName) {
            return String(feedURL.dropLast(legacyName.count)) + "/appcast-\(architecture.rawValue).xml"
        }
        return feedURL
    }
}
