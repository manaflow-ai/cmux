@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The Channels card's JSON (`cmux.settings.channels.state`): every text from the host, links
/// only to GitHub, and no compare link on the build this Mac runs.
struct ChannelsPageStateTests {
    private static func page() -> [String: Any] {
        let index = [
            ReleaseNotesIndexEntry(build: "300", shortVersion: "1.0.0-nightly.300", date: "2026-10-21", highlights: 1, head: "cccccccc"),
            ReleaseNotesIndexEntry(build: "200", shortVersion: "1.0.0-nightly.200", date: "2026-10-20", highlights: 0, head: "bbbbbbbb"),
        ]
        let tracks = ChannelTrack.tracks(index: index, verdicts: ["200": "pass"], pulled: [], installedBuild: "200",
                                         keptBuilds: [], followed: .nightly)
        let installed = tracks.lazy.compactMap(\.installed).first
        return UpdaterService.channelsPage(tracks: tracks, installed: installed, prs: ["300": [42]],
                                           installedVersion: "1.0.0-nightly.200")
    }

    private static func builds(_ page: [String: Any], ring: String) -> [[String: Any]] {
        let tracks = page["tracks"] as? [[String: Any]] ?? []
        return tracks.first { $0["ring"] as? String == ring }?["builds"] as? [[String: Any]] ?? []
    }

    @Test func everyRingIsATrackWithItsOwnTitleAndTheEmptyOnesSaySo() {
        let tracks = Self.page()["tracks"] as? [[String: Any]] ?? []
        #expect(tracks.compactMap { $0["ring"] as? String } == ["stable", "nightly", "canary", "dev"])
        #expect(tracks.compactMap { $0["title"] as? String } == ["Stable", "Nightly", "Canary", "Dev"])
        #expect(tracks[0]["empty"] as? String == "No builds on this channel yet.")
        #expect(tracks[1]["empty"] is NSNull)
        #expect(tracks[1]["followed"] as? Bool == true)
    }

    @Test func theNewerBuildLinksItsPRsAndTheChangesSinceTheInstalledOne() throws {
        let page = Self.page()
        let builds = Self.builds(page, ring: "nightly")
        try #require(builds.count == 2)
        let prs = builds[0]["prs"] as? [[String: Any]] ?? []
        #expect(prs.first?["number"] as? Int == 42)
        #expect(prs.first?["url"] as? String == "https://github.com/manaflow-ai/cmux/pull/42")
        #expect(builds[0]["compare_url"] as? String == "https://github.com/manaflow-ai/cmux/compare/bbbbbbbb...cccccccc")
        // No verdict: no badge, not "Awaiting Verdict" on every build.
        #expect(builds[0]["health"] as? String == "pending")
        #expect(builds[0]["health_title"] is NSNull)
        // The installed build: You Are Here, promoted, nothing to compare.
        #expect(builds[1]["installed"] as? Bool == true)
        #expect(builds[1]["compare_url"] is NSNull)
        #expect(builds[1]["health_title"] as? String == "Promoted")
        #expect(page["installed"] as? String == "This Mac runs 1.0.0-nightly.200.")
    }

    @Test func everyBuildButTheInstalledAndPulledOnesOffersSwitchOnAnAppThatFollowsAFeed() {
        let index = [
            ReleaseNotesIndexEntry(build: "300", shortVersion: "1.0.0-nightly.300", date: "2026-10-21", highlights: 0, head: nil),
            ReleaseNotesIndexEntry(build: "250", shortVersion: "1.0.0-nightly.250", date: "2026-10-20", highlights: 0, head: nil),
            ReleaseNotesIndexEntry(build: "200", shortVersion: "1.0.0-nightly.200", date: "2026-10-19", highlights: 0, head: nil),
            ReleaseNotesIndexEntry(build: "100", shortVersion: "1.0.0-nightly.100", date: "2026-10-18", highlights: 0, head: nil),
        ]
        let tracks = ChannelTrack.tracks(index: index, verdicts: [:], pulled: [PulledBuild(build: "250", reason: "crashes")],
                                         installedBuild: "200", keptBuilds: [], followed: .dev)
        let switching = UpdaterService.channelsPage(tracks: tracks, installed: nil, prs: [:], installedVersion: "1.0.0-nightly.200",
                                                    switches: true)
        let offered = Self.builds(switching, ring: "dev").filter { $0["switch"] as? Bool == true }.compactMap { $0["build"] as? String }
        // Newer and older alike.
        #expect(offered == ["300", "100"])
        #expect((switching["labels"] as? [String: Any])?["switch"] as? String == "Switch")
        // A local DEV build follows no feed: nothing offers Switch.
        let local = UpdaterService.channelsPage(tracks: tracks, installed: nil, prs: [:], installedVersion: "1.0.0-nightly.200")
        #expect(Self.builds(local, ring: "dev").allSatisfy { $0["switch"] as? Bool == false })
    }

    @Test func aNightlyBuildsDiskImageIsNamedForItsBuildBesideTheFeedAndOnlyForABuildNumber() {
        let folder = URL(string: "https://files-next.cmux.com/nightly-next/next/")!
        #expect(UpdaterService.nightlyDiskImageURL(build: "4132868957301", in: folder, architecture: .arm64)?.absoluteString
            == "https://files-next.cmux.com/nightly-next/next/cmux-nightly-next-macos-arm64-4132868957301.dmg")
        #expect(UpdaterService.nightlyDiskImageURL(build: "../x", in: folder) == nil)
        #expect(UpdaterService.nightlyDiskImageURL(build: "", in: folder) == nil)
        #expect(UpdaterService.nightlyDiskImageURL(build: "1", in: URL(string: "http://files-next.cmux.com/nightly-next/next/")!) == nil)
    }
}
