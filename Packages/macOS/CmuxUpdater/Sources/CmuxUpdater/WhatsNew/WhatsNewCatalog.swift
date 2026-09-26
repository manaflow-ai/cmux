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

        public var id: String { title }

        public init(title: String, description: String, tryIt: String? = nil, image: URL? = nil, video: URL? = nil) {
            self.title = title
            self.description = description
            self.tryIt = tryIt
            self.image = image
            self.video = video
        }

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
    public var features: [Feature]

    public var id: String { version }

    public init(version: String, title: String, url: URL? = nil, hero: URL? = nil, features: [Feature] = []) {
        self.version = version
        self.title = title
        self.url = url
        self.hero = hero
        self.features = features
    }

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
        features = decoded
    }

    private enum CodingKeys: String, CodingKey {
        case version, title, url, hero, features
    }

    /// Only https URLs load: the payload comes from the network.
    static func mediaURL(_ string: String?) -> URL? {
        guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https" else {
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
            guard WhatsNewVersion.compare(release.version, current) != .orderedDescending else { return false }
            guard let lastSeen else {
                return WhatsNewVersion.compare(release.version, current) == .orderedSame
            }
            return WhatsNewVersion.compare(release.version, lastSeen) == .orderedDescending
        }
        return Array(matching.prefix(max(0, limit)))
    }

    /// Releases for an on-demand recap, newest first: the newest releases at
    /// or below the running build, so a patch without highlights still shows
    /// the release before it.
    public func recentReleases(through current: String, limit: Int = 3) -> [WhatsNewRelease] {
        let matching = sortedReleases.filter {
            WhatsNewVersion.compare($0.version, current) != .orderedDescending
        }
        return Array(matching.prefix(max(0, limit)))
    }

    private var sortedReleases: [WhatsNewRelease] {
        releases
            .filter { !$0.features.isEmpty }
            .sorted { WhatsNewVersion.compare($0.version, $1.version) == .orderedDescending }
    }
}

/// Dotted-numeric version comparison; missing components count as zero.
public enum WhatsNewVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
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

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isASCII && $0.isNumber }) ?? 0
        }
    }
}

private struct Discarded: Decodable {
    init(from decoder: any Decoder) throws {}
}
