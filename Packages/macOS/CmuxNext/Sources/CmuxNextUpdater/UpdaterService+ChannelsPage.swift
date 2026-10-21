import CmuxUpdater
public import Foundation

/// The Settings > Updates Channels card (`cmux.settings.channels.run`, action `state`): every
/// ring's track as JSON for the page, each text localized here so the page draws no strings of
/// its own. Each build's PR numbers come from its signed notes (cached once verified).
extension UpdaterService {
    public func channelsPageState(limit: Int = 10) async -> [String: Any] {
        let tracks = await channelTracks(limit: limit)
        let installed = tracks.lazy.compactMap(\.installed).first
        let builds = tracks.flatMap(\.builds).map(\.build)
        var prs: [String: [Int]] = [:]
        if let store = changelogNotes {
            prs = await withTaskGroup(of: (String, [Int]).self) { group in
                for build in builds {
                    group.addTask { (build, Array((await store.notes(for: build)?.items ?? []).compactMap(\.pr).prefix(8))) }
                }
                var result: [String: [Int]] = [:]
                for await (build, numbers) in group { result[build] = numbers }
                return result
            }
        }
        return Self.channelsPage(tracks: tracks, installed: installed, prs: prs, installedVersion: identity.shortVersion)
    }

    nonisolated static func channelsPage(tracks: [ChannelTrack], installed: ChannelBuild?, prs: [String: [Int]],
                                         installedVersion: String) -> [String: Any] {
        [
            "title": UpdaterStrings.channelsTitle,
            "installed": UpdaterStrings.channelsInstalled(installedVersion),
            "labels": [
                "you_are_here": UpdaterStrings.channelsYouAreHere, "following": UpdaterStrings.channelsFollowing,
                "kept": UpdaterStrings.channelsKept, "compare": UpdaterStrings.channelsCompare,
                "commit": UpdaterStrings.channelsCommit, "release": UpdaterStrings.channelsRelease,
            ],
            "tracks": tracks.map { track -> [String: Any] in
                [
                    "ring": track.ring.rawValue, "title": channelTitle(track.ring), "followed": track.isFollowed,
                    "release_url": track.releaseURL?.absoluteString ?? NSNull(),
                    "empty": track.builds.isEmpty ? UpdaterStrings.channelsEmpty : NSNull(),
                    "builds": track.builds.map { build -> [String: Any] in
                        [
                            "build": build.build, "version": build.shortVersion, "date": build.date,
                            "commit": build.commit.map { String($0.prefix(8)) } ?? NSNull(),
                            "commit_url": build.commitURL?.absoluteString ?? NSNull(),
                            "compare_url": build.compareURL(from: installed)?.absoluteString ?? NSNull(),
                            "health": build.health.rawValue, "health_title": healthTitle(build.health),
                            "pulled_reason": build.pulledReason ?? NSNull(),
                            "installed": build.isInstalled, "kept": build.isKept,
                            "prs": (prs[build.build] ?? []).map { ["number": $0, "url": "\(ChannelBuild.repository)/pull/\($0)"] as [String: Any] },
                        ]
                    },
                ]
            },
        ]
    }

    nonisolated static func channelTitle(_ ring: UpdateRing) -> String {
        switch ring {
        case .stable: UpdaterStrings.channelStable
        case .nightly: UpdaterStrings.channelNightly
        case .canary: UpdaterStrings.channelCanary
        case .dev: UpdaterStrings.channelDev
        }
    }

    nonisolated static func healthTitle(_ health: ChannelBuild.Health) -> String {
        switch health {
        case .promoted: UpdaterStrings.channelsPromoted
        case .held: UpdaterStrings.channelsHeld
        case .pulled: UpdaterStrings.channelsPulled
        case .pending: UpdaterStrings.channelsPending
        }
    }
}

nonisolated extension UpdaterStrings {
    static var channelsTitle: String { text("updater.channels.title", "Channels") }
    static func channelsInstalled(_ version: String) -> String { format("updater.channels.installed", "This Mac runs %@.", version) }
    static var channelsYouAreHere: String { text("updater.channels.youAreHere", "You Are Here") }
    static var channelsFollowing: String { text("updater.channels.following", "Following") }
    static var channelsKept: String { text("updater.channels.kept", "Kept on This Mac") }
    static var channelsCompare: String { text("updater.channels.compare", "Changes Since Yours") }
    static var channelsCommit: String { text("updater.channels.commit", "Commit") }
    static var channelsRelease: String { text("updater.channels.release", "Release Page") }
    static var channelsEmpty: String { text("updater.channels.empty", "No builds on this channel yet.") }
    static var channelsPromoted: String { text("updater.channels.promoted", "Promoted") }
    static var channelsHeld: String { text("updater.channels.held", "Held") }
    static var channelsPulled: String { text("updater.channels.pulled", "Pulled") }
    static var channelsPending: String { text("updater.channels.pending", "Awaiting Verdict") }
    static var channelStable: String { text("updater.channels.ring.stable", "Stable") }
    static var channelNightly: String { text("updater.channels.ring.nightly", "Nightly") }
    static var channelCanary: String { text("updater.channels.ring.canary", "Canary") }
    static var channelDev: String { text("updater.channels.ring.dev", "Dev") }
}
