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
    /// The Nightly track is the feed's build index, each build with its canary verdict. Dev takes
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
    public static func tracks(index: [ReleaseNotesIndexEntry], verdicts: [String: String], pulled: [PulledBuild],
                              installedBuild: String, keptBuilds: Set<String>, followed: UpdateRing,
                              limit: Int = 10) -> [ChannelTrack] {
        let pulledByBuild = Dictionary(pulled.map { ($0.build, $0) }, uniquingKeysWith: { first, _ in first })
        let nightly = index.prefix(max(0, limit)).map { entry in
            ChannelBuild(build: entry.build, shortVersion: entry.shortVersion, date: entry.date, commit: entry.head,
                         health: pulledByBuild[entry.build] != nil ? .pulled : health(verdict: verdicts[entry.build]),
                         pulledReason: pulledByBuild[entry.build]?.reason,
                         isInstalled: entry.build == installedBuild, isKept: keptBuilds.contains(entry.build))
        }
        return UpdateRing.allCases.map { ring in
            ChannelTrack(ring: ring, builds: ring == .nightly || ring == .dev ? Array(nightly) : [], isFollowed: ring == followed,
                         releaseURL: ring == .nightly ? URL(string: "\(ChannelBuild.repository)/releases/tag/nightly-next") : nil)
        }
    }

    static func health(verdict: String?) -> ChannelBuild.Health {
        switch verdict {
        case "pass": .promoted
        case "fail": .held
        default: .pending
        }
    }
}
