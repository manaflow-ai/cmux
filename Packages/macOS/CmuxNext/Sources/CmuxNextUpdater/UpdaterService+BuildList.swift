public import Foundation

/// One recent build of this app's nightly track as `updates.builds` answers it (`cmux nightly list`):
/// the Channels card's Nightly row plus each build's first change titles, so a person picking a
/// build to go back to sees what it holds.
nonisolated public struct RecentBuild: Equatable, Sendable {
    public var build: String
    public var version: String
    /// `YYYY-MM-DD`, as `notes/index.json` writes it.
    public var date: String
    public var commit: String?
    /// ``ChannelBuild/Health``'s raw value: promoted, held, pulled or pending.
    public var health: String
    public var pulledReason: String?
    public var installed: Bool
    public var kept: Bool
    /// ``UpdaterService/switchToBuild(_:)`` would take it: any build but the installed and pulled
    /// ones, on an app that switches builds.
    public var switchable: Bool
    /// The build's newest change titles (its signed notes), at most three.
    public var titles: [String]
}

/// Leo (2026-11-02): "austin and aziz hit it for some reason so idk if i should go without a way to
/// revert nightlies to an older version convieniently". The list the palette's Install an Earlier
/// Nightly… shows in Settings and `cmux nightly list|install` reads; the install itself is
/// ``switchToBuild(_:)``, which skips the build left behind so the updater does not bring it back.
extension UpdaterService {
    /// Why Install an Earlier Nightly… cannot run here (a build that follows no feed), else nil.
    public var installEarlierBuildUnavailableReason: String? {
        switchesBuilds ? nil : UpdaterStrings.channelsSwitchUnavailable
    }

    /// The nightly track's recent builds, newest first, from the files the feed already publishes.
    public func recentBuilds(limit: Int = 10) async -> [RecentBuild] {
        let tracks = await channelTracks(limit: limit)
        let builds = tracks.first(where: { $0.ring == .nightly && !$0.builds.isEmpty })?.builds
            ?? tracks.first(where: { !$0.builds.isEmpty })?.builds ?? []
        let store = changelogNotes
        let titles: [String: [String]] = await withTaskGroup(of: (String, [String]).self) { group in
            for build in builds.map(\.build) {
                group.addTask { (build, Array((await store?.notes(for: build)?.items ?? []).map(\.title).prefix(3))) }
            }
            var result: [String: [String]] = [:]
            for await (build, list) in group { result[build] = list }
            return result
        }
        return Self.recentBuilds(builds, titles: titles, switches: switchesBuilds)
    }

    /// `updates.builds`' `limit`: 1 to 50, 10 when absent; a fraction rounds down, and a value no
    /// `Int` holds (1e308, NaN, infinity) is the default instead of a trap.
    nonisolated public static func recentBuildsLimit(_ value: Double?) -> Int {
        guard let value, value.isFinite, let whole = Int(exactly: value.rounded(.down)) else { return 10 }
        return max(1, min(50, whole))
    }

    nonisolated static func recentBuilds(_ builds: [ChannelBuild], titles: [String: [String]], switches: Bool) -> [RecentBuild] {
        builds.map { build in
            RecentBuild(build: build.build, version: build.shortVersion, date: build.date, commit: build.commit,
                        health: build.health.rawValue, pulledReason: build.pulledReason, installed: build.isInstalled,
                        kept: build.isKept, switchable: switches && !build.isInstalled && build.health != .pulled,
                        titles: titles[build.build] ?? [])
        }
    }
}
