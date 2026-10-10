public import Foundation

/// One release's highlights, as the changelog page shows them.
///
/// Served by `https://cmux.com/api/changelog/highlights`, which reads the same
/// `changelog-media.ts` entries as `cmux.com/docs/changelog`, so the app and
/// the website never disagree about what a release contains.
public struct WhatsNewRelease: Decodable, Equatable, Identifiable, Sendable {
    /// One feature card.
    public struct Feature: Decodable, Equatable, Identifiable, Sendable {
        public var title: String
        public var description: String
        /// A one-line "how to try it" hint, when the entry has one.
        public var tryIt: String?
        public var image: URL?
        public var video: URL?

        /// The feature's position in its release. Titles are hand-written
        /// and can repeat, so identity comes from where the card sits;
        /// ``WhatsNewRelease`` assigns it whenever it takes its features.
        public fileprivate(set) var id: Int = 0

        /// Creates a feature card. Its ``id`` is assigned by the release that holds it.
        public init(title: String, description: String, tryIt: String? = nil, image: URL? = nil, video: URL? = nil) {
            self.title = title
            self.description = description
            self.tryIt = tryIt
            self.image = image
            self.video = video
        }

        /// Decodes one card; a blank `tryIt` and media that is not an https
        /// cmux.com URL are dropped.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            description = try container.decode(String.self, forKey: .description)
            tryIt = (try? container.decodeIfPresent(String.self, forKey: .tryIt))?
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            image = WhatsNewRelease.mediaURL(try? container.decodeIfPresent(String.self, forKey: .image))
            video = WhatsNewRelease.mediaURL(try? container.decodeIfPresent(String.self, forKey: .video))
        }

        private enum CodingKeys: String, CodingKey {
            case title, description, tryIt, image, video
        }
    }

    public var version: String
    public var title: String
    /// The release's full changelog page.
    public var url: URL?
    public var hero: URL?
    /// The feature cards in display order, each identified by its position.
    public var features: [Feature] {
        didSet { Self.numberFeatures(&features) }
    }

    public var id: String { version }

    /// Creates a release; its features are numbered in order.
    public init(version: String, title: String, url: URL? = nil, hero: URL? = nil, features: [Feature] = []) {
        self.version = version
        self.title = title
        self.url = url
        self.hero = hero
        var numbered = features
        Self.numberFeatures(&numbered)
        self.features = numbered
    }

    /// Decodes lossily: a malformed feature drops that card, not the release.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        title = try container.decode(String.self, forKey: .title)
        url = Self.mediaURL(try? container.decodeIfPresent(String.self, forKey: .url))
        hero = Self.mediaURL(try? container.decodeIfPresent(String.self, forKey: .hero))
        var decoded: [Feature] = []
        if var elements = try? container.nestedUnkeyedContainer(forKey: .features) {
            while !elements.isAtEnd {
                if let feature = try? elements.decode(Feature.self) {
                    decoded.append(feature)
                } else {
                    _ = try? elements.decode(Discarded.self)
                }
            }
        }
        Self.numberFeatures(&decoded)
        features = decoded
    }

    /// Gives each feature its position as its identity.
    private static func numberFeatures(_ features: inout [Feature]) {
        for index in features.indices where features[index].id != index {
            features[index].id = index
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, url, hero, features
    }

    /// Only https cmux.com URLs load. The payload comes from the network, and
    /// these strings become `NSWorkspace.open` targets and image and video
    /// loads, so the scheme alone is not enough: an arbitrary host would be a
    /// link-injection and request-leak path if the endpoint were ever wrong.
    static func mediaURL(_ string: String?) -> URL? {
        guard let string,
              let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "cmux.com" || host.hasSuffix(".cmux.com")
        else {
            return nil
        }
        return url
    }
}

/// The highlights list, newest release first, and the selection rules for the
/// recap.
public struct WhatsNewCatalog: Decodable, Equatable, Sendable {
    /// The endpoint the app reads.
    public static let endpoint = URL(string: "https://cmux.com/api/changelog/highlights")!
    /// Where the recap links when a release has no page of its own.
    public static let changelogPage = URL(string: "https://cmux.com/docs/changelog")!

    public var releases: [WhatsNewRelease]

    /// Creates a catalog from already-decoded releases.
    public init(releases: [WhatsNewRelease]) {
        self.releases = releases
    }

    /// Decodes lossily: one malformed release drops that release, not the list.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        var decoded: [WhatsNewRelease] = []
        var elements = try container.nestedUnkeyedContainer(forKey: .releases)
        while !elements.isAtEnd {
            if let release = try? elements.decode(WhatsNewRelease.self) {
                decoded.append(release)
            } else {
                _ = try? elements.decode(Discarded.self)
            }
        }
        releases = decoded
    }

    private enum CodingKeys: String, CodingKey {
        case releases
    }

    /// Decodes the endpoint's JSON body.
    public static func decode(_ data: Data) throws -> WhatsNewCatalog {
        try JSONDecoder().decode(WhatsNewCatalog.self, from: data)
    }

    /// Releases to announce after an update, newest first.
    ///
    /// - Parameters:
    ///   - lastSeen: The release key the user last saw, or `nil` when nothing
    ///     is recorded; then only the current release is announced.
    ///   - current: The running build's release key.
    ///   - limit: The most releases to include.
    /// - Returns: Releases with highlights in `(lastSeen, current]`. A release
    ///   newer than the running build is never included, and a `lastSeen`
    ///   newer than `current` (a downgrade) announces nothing.
    public func releasesToAnnounce(after lastSeen: String?, through current: String, limit: Int = 3) -> [WhatsNewRelease] {
        let matching = sortedReleases.filter { release in
            guard comparator.compare(release.version, current) != .orderedDescending else { return false }
            guard let lastSeen else {
                return comparator.compare(release.version, current) == .orderedSame
            }
            return comparator.compare(release.version, lastSeen) == .orderedDescending
        }
        return Array(matching.prefix(max(0, limit)))
    }

    /// Releases for an on-demand recap, newest first: the newest releases at
    /// or below the running build, so a patch without highlights still shows
    /// the release before it.
    public func recentReleases(through current: String, limit: Int = 3) -> [WhatsNewRelease] {
        let matching = sortedReleases.filter {
            comparator.compare($0.version, current) != .orderedDescending
        }
        return Array(matching.prefix(max(0, limit)))
    }

    private var comparator: WhatsNewVersionComparator { WhatsNewVersionComparator() }

    private var sortedReleases: [WhatsNewRelease] {
        releases
            .filter { !$0.features.isEmpty }
            .sorted { comparator.compare($0.version, $1.version) == .orderedDescending }
    }
}

/// Dotted-numeric version comparison; missing components count as zero.
public struct WhatsNewVersionComparator: Sendable {
    /// Creates a comparator.
    public init() {}

    /// Orders two dotted versions numerically, so `0.64.10` follows `0.64.9`.
    public func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Each dot-separated component's leading digits; a component without any counts as zero.
    private func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }
}

private struct Discarded: Decodable {
    init(from decoder: any Decoder) throws {}
}
