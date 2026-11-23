public import CmuxUpdater
public import Foundation

/// One build on a release channel's track (Settings > Updates, the channels view): what it is,
/// how it fared, and whether this Mac runs it or kept it for an instant rollback.
nonisolated public struct ChannelBuild: Equatable, Sendable {
    /// How the build fared after it was published.
    public enum Health: String, Equatable, Sendable {
        /// Its canary verdict passed: it was promoted.
        case promoted
        /// Its canary verdict failed: it is held where it is.
        case held
        /// It was taken off the feed (`pulled.json`).
        case pulled
        /// No verdict yet, or the canary skipped it: no badge (most builds; the canary rates few).
        case pending
    }

    public var build: String
    public var shortVersion: String
    /// The day it was published (`YYYY-MM-DD`, as `notes/index.json` writes it).
    public var date: String
    /// The commit it was built from, when the feed says.
    public var commit: String?
    public var health: Health
    /// Why it was pulled, for a pulled build.
    public var pulledReason: String?
    /// This Mac runs it ("You are here").
    public var isInstalled: Bool
    /// This Mac kept a copy, so installing it is an instant rollback.
    public var isKept: Bool

    public init(build: String, shortVersion: String, date: String, commit: String? = nil, health: Health = .pending,
                pulledReason: String? = nil, isInstalled: Bool = false, isKept: Bool = false) {
        self.build = build
        self.shortVersion = shortVersion
        self.date = date
        self.commit = commit
        self.health = health
        self.pulledReason = pulledReason
        self.isInstalled = isInstalled
        self.isKept = isKept
    }

    /// The GitHub commit page the build was cut from.
    public var commitURL: URL? {
        commit.flatMap { Self.isCommit($0) ? URL(string: "\(Self.repository)/commit/\($0)") : nil }
    }

    /// GitHub's compare page from `installed` to this build: what changes on installing it.
    /// Nil for the installed build itself or when either commit is unknown.
    public func compareURL(from installed: ChannelBuild?) -> URL? {
        guard let from = installed?.commit, let to = commit, from != to, Self.isCommit(from), Self.isCommit(to) else { return nil }
        return URL(string: "\(Self.repository)/compare/\(from)...\(to)")
    }

    static let repository = "https://github.com/manaflow-ai/cmux"

    /// A hex commit id, so a feed value never becomes another URL path.
    static func isCommit(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }
}

/// One release channel's recent builds, newest first.
nonisolated public struct ChannelTrack: Equatable, Sendable {
    public var ring: UpdateRing
    public var builds: [ChannelBuild]
    /// The channel this Mac follows (`updates.channel`).
    public var isFollowed: Bool
    /// The GitHub release that holds this channel's downloads.
    public var releaseURL: URL?

    public init(ring: UpdateRing, builds: [ChannelBuild], isFollowed: Bool, releaseURL: URL? = nil) {
        self.ring = ring
        self.builds = builds
        self.isFollowed = isFollowed
        self.releaseURL = releaseURL
    }

    /// The build this Mac runs, when it is on this track.
    public var installed: ChannelBuild? { builds.first(where: \.isInstalled) }

    /// The tracks shown today, one per ring, slowest first (Stable, Nightly, Canary, Dev).
    /// The Nightly track is every build the appcast offers this Mac's ring plus the older builds
    /// the feed's build index still lists (the appcast keeps only its newest items), each with its
    /// canary verdict or pull. The appcast decides which builds exist: a build it offers whose
    /// notes are not published yet is listed (no commit, no titles) and switchable, so the list
    /// never trails what the updater installs. Dev takes
    /// every build CI publishes (`cmux-next-dev` first, then `cmux-next` once promoted), so its
    /// track is the same index; Stable and Canary have no builds until CI publishes them.
    /// - Parameters:
    ///   - index: `notes/index.json`, newest first.
    ///   - verdicts: each build's canary verdict (`verdicts/<build>.json`: pass, fail, skipped).
    ///   - pulled: the feed's `pulled.json`.
    ///   - installedBuild: the running build.
    ///   - keptBuilds: the builds this Mac kept for rollback.
    ///   - followed: the ring `updates.channel` picks.
    ///   - limit: how many recent builds a track shows.
    ///   - feedItems: this app's own feed. The Dev track also lists its builds the index lacks: the
    ///     published DEV app's tip feed has no notes index, so its builds come only from there.
    ///   - tipFeed: `feedItems` is the DEV app's tip feed, whose builds are not nightlies: the
    ///     Nightly track stays the index alone.
    public static func tracks(index: [ReleaseNotesIndexEntry], verdicts: [String: String], pulled: [PulledBuild],
                              installedBuild: String, keptBuilds: Set<String>, followed: UpdateRing,
                              limit: Int = 10, feedItems: [AppcastItem] = [], tipFeed: Bool = false) -> [ChannelTrack] {
        let pulledByBuild = Dictionary(pulled.map { ($0.build, $0) }, uniquingKeysWith: { first, _ in first })
        let fromIndex = index.prefix(max(0, limit)).map { entry in
            ChannelBuild(build: entry.build, shortVersion: entry.shortVersion, date: entry.date, commit: entry.head,
                         health: pulledByBuild[entry.build] != nil ? .pulled : health(verdict: verdicts[entry.build]),
                         pulledReason: pulledByBuild[entry.build]?.reason,
                         isInstalled: entry.build == installedBuild, isKept: keptBuilds.contains(entry.build))
        }
        let ahead = tipFeed ? [] : nightlyFeedOnly(feedItems, index: index, followed: followed).map { item in
            ChannelBuild(build: item.version, shortVersion: item.displayVersion, date: item.date.map(day) ?? "",
                         health: pulledByBuild[item.version] != nil ? .pulled : health(verdict: verdicts[item.version]),
                         pulledReason: pulledByBuild[item.version]?.reason,
                         isInstalled: item.version == installedBuild, isKept: keptBuilds.contains(item.version))
        }
        let nightly = (fromIndex + ahead).sorted { KeptVersionStore.isNewer($0.build, than: $1.build) }.prefix(max(0, limit))
        let indexed = Set(index.map(\.build))
        let fromFeed = feedItems.filter { !indexed.contains($0.version) && pulledByBuild[$0.version] == nil }.map { item in
            ChannelBuild(build: item.version, shortVersion: item.displayVersion, date: item.date.map(day) ?? "",
                         isInstalled: item.version == installedBuild, isKept: keptBuilds.contains(item.version))
        }
        let dev = (nightly + fromFeed).sorted { KeptVersionStore.isNewer($0.build, than: $1.build) }.prefix(max(0, limit))
        return UpdateRing.allCases.map { ring in
            ChannelTrack(ring: ring, builds: ring == .nightly ? Array(nightly) : ring == .dev ? Array(dev) : [],
                         isFollowed: ring == followed,
                         releaseURL: ring == .nightly ? URL(string: "\(ChannelBuild.repository)/releases/tag/nightly-next") : nil)
        }
    }

    /// The appcast's items the Nightly track lists that the notes index lacks: each one the
    /// updater offers on the Nightly ring or the followed one, whichever is faster (the rings are a
    /// ladder), so the running build is never missing from its own list.
    static func nightlyFeedOnly(_ feedItems: [AppcastItem], index: [ReleaseNotesIndexEntry], followed: UpdateRing) -> [AppcastItem] {
        let indexed = Set(index.map(\.build))
        let accepted = UpdateRing.nightly.acceptedSparkleChannels.union(followed.acceptedSparkleChannels)
        var seen = Set<String>()
        return feedItems.filter { item in
            !item.version.isEmpty && !indexed.contains(item.version) && item.isOffered(allowing: accepted)
                && seen.insert(item.version).inserted
        }
    }

    /// `YYYY-MM-DD` in UTC, as `notes/index.json` writes a build's day.
    static func day(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: .gmt).year().month().day())
    }

    static func health(verdict: String?) -> ChannelBuild.Health {
        switch verdict {
        case "pass": .promoted
        case "fail": .held
        default: .pending
        }
    }
}
