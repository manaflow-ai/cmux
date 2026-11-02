public import CmuxUpdater
public import Foundation

/// One build on a release channel's track (Settings > Updates, the channels view): what it is,
/// how it fared, and whether this Mac runs it or kept it for an instant rollback.
nonisolated public struct ChannelBuild: Equatable, Sendable {
    /// How the build fared after it was published.
    public enum Health: String, Equatable, Sendable, Decodable {
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
    /// The GitHub commit page the build was cut from; only a hex commit id becomes a link.
    public var commitURL: URL?
    /// GitHub's compare page from the track's installed build to this one: what changes on
    /// installing it. Nil for the installed build itself or when either commit is unknown.
    public var compareURL: URL?

    public init(build: String, shortVersion: String, date: String, commit: String? = nil, health: Health = .pending,
                pulledReason: String? = nil, isInstalled: Bool = false, isKept: Bool = false,
                commitURL: URL? = nil, compareURL: URL? = nil) {
        self.build = build
        self.shortVersion = shortVersion
        self.date = date
        self.commit = commit
        self.health = health
        self.pulledReason = pulledReason
        self.isInstalled = isInstalled
        self.isKept = isKept
        self.commitURL = commitURL
        self.compareURL = compareURL
    }

    static let repository = "https://github.com/manaflow-ai/cmux"
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

    /// The tracks shown today, one per ring, slowest first, from the update rules
    /// (cmux-updater-core `updater_channel_tracks`): the Nightly track is the feed's build index
    /// with each build's canary verdict or pull; Dev takes every build CI publishes (the index
    /// and this app's own feed, newest first); Stable and Canary have no builds until CI
    /// publishes them.
    /// - Parameters:
    ///   - index: `notes/index.json`, newest first.
    ///   - verdicts: each build's canary verdict (`verdicts/<build>.json`: pass, fail, skipped).
    ///   - pulled: the feed's `pulled.json`.
    ///   - installedBuild: the running build.
    ///   - keptBuilds: the builds this Mac kept for rollback.
    ///   - followed: the ring `updates.channel` picks.
    ///   - limit: how many recent builds a track shows.
    ///   - feedItems: this app's own feed (the published DEV app's tip feed has no notes index).
    public static func tracks(index: [ReleaseNotesIndexEntry], verdicts: [String: String], pulled: [PulledBuild],
                              installedBuild: String, keptBuilds: Set<String>, followed: UpdateRing,
                              limit: Int = 10, feedItems: [AppcastItem] = []) -> [ChannelTrack] {
        let request = TracksRequest(
            index: index.map { TracksRequest.Entry(build: $0.build, shortVersion: $0.shortVersion, date: $0.date, head: $0.head) },
            verdicts: verdicts,
            pulled: pulled.map { TracksRequest.Pulled(build: $0.build, reason: $0.reason) },
            installedBuild: installedBuild, keptBuilds: keptBuilds.sorted(), followed: followed.rawValue, limit: limit,
            feedItems: feedItems.map { TracksRequest.Feed(version: $0.version, displayVersion: $0.displayVersion,
                                                          date: $0.date?.timeIntervalSince1970) })
        guard let answer: TracksAnswer = UpdaterRules().call("updater_channel_tracks", json: request) else { return [] }
        return answer.tracks.compactMap { track in
            guard let ring = UpdateRing(rawValue: track.ring) else { return nil }
            return ChannelTrack(ring: ring, builds: track.builds.map(\.channelBuild), isFollowed: track.isFollowed,
                                releaseURL: track.releaseUrl.flatMap(URL.init(string:)))
        }
    }
}

nonisolated private struct TracksRequest: Encodable {
    nonisolated struct Entry: Encodable {
        var build: String
        var shortVersion: String
        var date: String
        var head: String?
    }

    nonisolated struct Pulled: Encodable {
        var build: String
        var reason: String
    }

    nonisolated struct Feed: Encodable {
        var version: String
        var displayVersion: String
        var date: Double?
    }

    var index: [Entry]
    var verdicts: [String: String]
    var pulled: [Pulled]
    var installedBuild: String
    var keptBuilds: [String]
    var followed: String
    var limit: Int
    var feedItems: [Feed]
}

nonisolated private struct TracksAnswer: Decodable {
    nonisolated struct Build: Decodable {
        var build: String
        var shortVersion: String
        var date: String
        var commit: String?
        var health: ChannelBuild.Health
        var pulledReason: String?
        var isInstalled: Bool
        var isKept: Bool
        var commitUrl: String?
        var compareUrl: String?
    }

    nonisolated struct Track: Decodable {
        var ring: String
        var builds: [Build]
        var isFollowed: Bool
        var releaseUrl: String?
    }

    var tracks: [Track]
}

extension TracksAnswer.Build {
    nonisolated var channelBuild: ChannelBuild {
        ChannelBuild(build: build, shortVersion: shortVersion, date: date, commit: commit, health: health,
                     pulledReason: pulledReason, isInstalled: isInstalled, isKept: isKept,
                     commitURL: commitUrl.flatMap(URL.init(string:)), compareURL: compareUrl.flatMap(URL.init(string:)))
    }
}
