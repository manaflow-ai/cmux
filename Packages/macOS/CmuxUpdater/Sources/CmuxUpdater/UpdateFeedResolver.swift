import Foundation

/// Resolves which Sparkle appcast feed URL the updater should use, given the URL baked
/// into the app's `Info.plist` at build time.
///
/// Stable releases ship with the stable appcast URL; `cmux NIGHTLY` and `cmux RC` have their
/// channel appcast URL injected by CI. When the `Info.plist` value is missing or empty the
/// resolver falls back to the latest-release appcast so the updater still has a feed to query.
///
/// Nightly and RC feeds are per architecture. A channel `appcast.xml` (or the older
/// `appcast-universal.xml`) URL is rewritten to `appcast-arm64.xml` or `appcast-x86_64.xml`
/// for the host machine, so a universal build migrates itself onto the thin build and an
/// x86_64 build running under Rosetta moves to the native one.
///
/// Release candidates share the stable bundle identifier, so the user picks the channel in
/// settings (``UpdateChannelSelection``). Selecting `rc` on a stable build-time feed swaps in
/// ``rcFeedURL`` before the per-architecture rewrite; nightly builds ignore the selection.
///
/// ```swift
/// let resolver = UpdateFeedResolver()
/// let resolution = resolver.resolve(
///     infoFeedURL: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
///     selectedChannel: .rc
/// )
/// updater.setFeedURL(resolution.url)
/// ```
public struct UpdateFeedResolver: Sendable {
    /// The release channel a feed URL belongs to, classified from its path.
    public enum Channel: String, Equatable, Sendable {
        /// The shipping release feed (or the fallback latest-release feed).
        case stable
        /// The nightly feed; its path contains `/nightly/`.
        case nightly
        /// The release-candidate feed; its path contains `/rc/`.
        case rc

        /// Classifies `feedURL` by the channel path segment it contains.
        static func classify(feedURL: String) -> Channel {
            if feedURL.contains("/nightly/") {
                return .nightly
            }
            if feedURL.contains("/rc/") {
                return .rc
            }
            return .stable
        }

        /// Whether this channel publishes one appcast per architecture.
        var usesPerArchitectureFeeds: Bool {
            switch self {
            case .stable: false
            case .nightly, .rc: true
            }
        }
    }

    /// The outcome of resolving a feed URL: the URL to use plus how it was classified.
    public struct Resolution: Equatable, Sendable {
        /// The feed URL the updater should query.
        public let url: String
        /// The channel `url` points at.
        public let channel: Channel
        /// Whether `url` came from ``UpdateFeedResolver/fallbackFeedURL`` because the
        /// `Info.plist` feed URL was missing or empty.
        public let usedFallback: Bool

        /// Whether `url` points at the nightly channel (its path contains `/nightly/`).
        public var isNightly: Bool { channel == .nightly }

        /// Creates a resolution result.
        public init(url: String, channel: Channel, usedFallback: Bool) {
            self.url = url
            self.channel = channel
            self.usedFallback = usedFallback
        }
    }

    /// The appcast URL used when the `Info.plist` feed URL is missing or empty.
    public let fallbackFeedURL: String
    /// The release-candidate appcast a stable build switches to when the user selects the
    /// `rc` channel. Rewritten per architecture like a CI-injected RC feed.
    public let rcFeedURL: String
    /// The architecture nightly and RC feeds are resolved for.
    public let hostArchitecture: UpdateHostArchitecture

    /// Creates a resolver.
    ///
    /// - Parameters:
    ///   - fallbackFeedURL: The appcast URL to fall back to when the build-time feed URL is
    ///     absent. Defaults to the project's latest-release appcast.
    ///   - rcFeedURL: The release-candidate appcast used when the user selects the `rc`
    ///     channel on a stable build. Defaults to the project's RC appcast.
    ///   - hostArchitecture: The architecture to select nightly and RC feeds for. Defaults to the
    ///     machine's native architecture.
    public init(
        fallbackFeedURL: String = "https://github.com/manaflow-ai/cmux/releases/latest/download/appcast.xml",
        rcFeedURL: String = "https://files.cmux.com/rc/appcast.xml",
        hostArchitecture: UpdateHostArchitecture = .current
    ) {
        self.fallbackFeedURL = fallbackFeedURL
        self.rcFeedURL = rcFeedURL
        self.hostArchitecture = hostArchitecture
    }

    /// Resolves the feed URL to use.
    ///
    /// - Parameters:
    ///   - infoFeedURL: The `SUFeedURL` value from the app's `Info.plist`, if any.
    ///   - selectedChannel: The channel the user selected in settings. Defaults to `stable`,
    ///     which leaves the build-time feed untouched. `rc` replaces a stable build-time feed
    ///     (or the fallback) with ``rcFeedURL``; a nightly or CI-injected RC feed is kept.
    /// - Returns: The resolved URL plus its channel and whether the fallback was used.
    public func resolve(infoFeedURL: String?, selectedChannel: UpdateChannelSelection = .stable) -> Resolution {
        let buildFeed: Resolution
        if let infoFeedURL, !infoFeedURL.isEmpty {
            buildFeed = Resolution(url: infoFeedURL, channel: Channel.classify(feedURL: infoFeedURL), usedFallback: false)
        } else {
            buildFeed = Resolution(url: fallbackFeedURL, channel: .stable, usedFallback: true)
        }
        let selected: Resolution
        if buildFeed.channel == .stable, selectedChannel == .rc {
            selected = Resolution(url: rcFeedURL, channel: .rc, usedFallback: false)
        } else {
            selected = buildFeed
        }
        let url = selected.channel.usesPerArchitectureFeeds
            ? Self.architectureSpecificFeedURL(selected.url, architecture: hostArchitecture)
            : selected.url
        return Resolution(url: url, channel: selected.channel, usedFallback: selected.usedFallback)
    }

    /// Rewrites a nightly or RC feed URL whose file name is the legacy `appcast.xml` or
    /// `appcast-universal.xml` to the per-architecture feed. URLs that already name an
    /// architecture, or use another file name, are returned unchanged.
    static func architectureSpecificFeedURL(_ feedURL: String, architecture: UpdateHostArchitecture) -> String {
        for legacyName in ["/appcast.xml", "/appcast-universal.xml"] where feedURL.hasSuffix(legacyName) {
            return String(feedURL.dropLast(legacyName.count)) + "/appcast-\(architecture.rawValue).xml"
        }
        return feedURL
    }
}
