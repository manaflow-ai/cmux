public import CmuxUpdater
public import Foundation

/// The Settings > Updates Channels card (`cmux.settings.channels.state`): every
/// ring's track as JSON for the page, each text localized here so the page draws no strings of
/// its own. Each build's PRs (every one, with its title) come from its signed notes (cached once
/// verified), so the card answers which PRs went into which build (Leo: "hm do we display which prs
/// go into which nightly maybe that'd be useful per thing?"). `ring` is
/// the Channel row's value, which can move before the setting reaches the updater; its way back
/// (``ringReturn(to:)``) is the card's `switch`.
extension UpdaterService {
    public func channelsPageState(ring: UpdateRing? = nil, limit: Int = 10) async -> [String: Any] {
        let shown = ring ?? self.ring
        async let way = ringReturn(to: shown)
        let tracks = await channelTracks(limit: limit)
        let installed = tracks.lazy.compactMap(\.installed).first
        let builds = tracks.flatMap(\.builds).map(\.build)
        var prs: [String: [ChannelPR]] = [:]
        if let store = changelogNotes {
            prs = await withTaskGroup(of: (String, [ChannelPR]).self) { group in
                for build in builds {
                    group.addTask { (build, ChannelPR.list(await store.notes(for: build)?.items ?? [])) }
                }
                var result: [String: [ChannelPR]] = [:]
                for await (build, numbers) in group { result[build] = numbers }
                return result
            }
        }
        return Self.channelsPage(tracks: tracks, installed: installed, prs: prs, installedVersion: identity.shortVersion,
                                 ring: shown, way: await way, switches: switchesBuilds)
    }

    /// - Parameter switches: this app can switch builds (``switchesBuilds``): every build but the
    ///   installed and pulled ones gets the Switch button.
    nonisolated static func channelsPage(tracks: [ChannelTrack], installed: ChannelBuild?, prs: [String: [ChannelPR]],
                                         installedVersion: String, ring: UpdateRing = .nightly,
                                         way: RingReturn = .none, switches: Bool = false) -> [String: Any] {
        [
            "title": UpdaterStrings.channelsTitle,
            "installed": UpdaterStrings.channelsInstalled(installedVersion),
            "switch": switchState(ring: ring, way: way, installedVersion: installedVersion),
            "labels": [
                "you_are_here": UpdaterStrings.channelsYouAreHere, "following": UpdaterStrings.channelsFollowing,
                "kept": UpdaterStrings.channelsKept, "compare": UpdaterStrings.channelsCompare,
                "commit": UpdaterStrings.channelsCommit, "release": UpdaterStrings.channelsRelease,
                "switch": UpdaterStrings.channelsSwitch,
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
                            "health": build.health.rawValue, "health_title": healthTitle(build.health) ?? NSNull(),
                            "pulled_reason": build.pulledReason ?? NSNull(),
                            "installed": build.isInstalled, "kept": build.isKept,
                            "switch": switches && !build.isInstalled && build.health != .pulled,
                            "prs": (prs[build.build] ?? []).map {
                                ["number": $0.number, "title": $0.title, "url": "\(ChannelBuild.repository)/pull/\($0.number)"] as [String: Any]
                            },
                            "prs_label": prs[build.build].map { UpdaterStrings.channelsPRs($0.count) } ?? NSNull(),
                        ]
                    },
                ]
            },
        ]
    }

    /// The way back to `ring` (``RingReturn``): a Go Back button into the kept build, a line that
    /// the running build stays, or nothing.
    nonisolated static func switchState(ring: UpdateRing, way: RingReturn, installedVersion: String) -> Any {
        switch way {
        case .none:
            NSNull()
        case .goBack(let kept):
            [
                "ring": ring.rawValue, "build": kept.build, "action": UpdaterStrings.channelsGoBack(channelTitle(ring)),
                "detail": UpdaterStrings.channelsGoBackDetail(kept.shortVersion),
            ] as [String: Any]
        case .waits:
            ["ring": ring.rawValue, "build": NSNull(), "action": NSNull(),
             "detail": UpdaterStrings.channelsWaits(installedVersion, channelTitle(ring))] as [String: Any]
        }
    }

    nonisolated static func channelTitle(_ ring: UpdateRing) -> String {
        switch ring {
        case .stable: UpdaterStrings.channelStable
        case .nightly: UpdaterStrings.channelNightly
        case .canary: UpdaterStrings.channelCanary
        case .dev: UpdaterStrings.channelDev
        }
    }

    /// The build's badge; nil for a build with no canary verdict, which shows none. The canary
    /// rates few builds, so "Awaiting Verdict" sat on nearly every build, also ones days old
    /// (Leo: "what is #2 going on there awaiting verdict? i fele like ui could be improvedthere").
    nonisolated static func healthTitle(_ health: ChannelBuild.Health) -> String? {
        switch health {
        case .promoted: UpdaterStrings.channelsPromoted
        case .held: UpdaterStrings.channelsHeld
        case .pulled: UpdaterStrings.channelsPulled
        case .pending: nil
        }
    }
}

/// One PR of a build on the Channels card: its number and title from the build's signed notes.
struct ChannelPR: Equatable, Sendable {
    let number: Int
    let title: String

    /// Every PR of the notes once, in their order; items with no PR (direct commits) are left out.
    nonisolated static func list(_ items: [ReleaseNotes.ChangeItem]) -> [ChannelPR] {
        var seen = Set<Int>()
        return items.compactMap { item in
            guard let number = item.pr, seen.insert(number).inserted else { return nil }
            return ChannelPR(number: number, title: item.title)
        }
    }
}

nonisolated extension UpdaterStrings {
    static func channelsPRs(_ count: Int) -> String { format("updater.channels.prs", "PRs (%lld)", count) }
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
    static func channelsGoBack(_ channel: String) -> String { format("updater.channels.goBack", "Go Back to %@", channel) }
    static func channelsGoBackDetail(_ version: String) -> String {
        format("updater.channels.goBackDetail", "Restarts once into %@, kept on this Mac. Settings and sessions stay.", version)
    }
    static func channelsWaits(_ version: String, _ channel: String) -> String {
        format("updater.channels.waits", "This Mac stays on %1$@ until %2$@ reaches a newer build.", version, channel)
    }
    static var channelsGoBackGone: String { text("updater.channels.goBackGone", "That kept build is no longer the way back.") }
    static var channelStable: String { text("updater.channels.ring.stable", "Stable") }
    static var channelNightly: String { text("updater.channels.ring.nightly", "Nightly") }
    static var channelCanary: String { text("updater.channels.ring.canary", "Canary") }
    static var channelDev: String { text("updater.channels.ring.dev", "Dev") }
}
